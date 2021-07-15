#include <cuda_runtime.h>
#include "dCOO.h"
#include "union_find.hxx"
#include "time_measure_util.h"
#include <algorithm>
#include <cstdlib>
#include "external/ECL-CC/ECLgraph.h"
#include <thrust/transform_scan.h>
#include <thrust/transform.h>
#include "maximum_matching_vertex_based.h"
#include "icp_small_cycles.h"
#include "utils.h"

thrust::device_vector<int> compress_label_sequence(const thrust::device_vector<int>& data, const int max_label)
{
    MEASURE_CUMULATIVE_FUNCTION_EXECUTION_TIME;

    assert(*thrust::max_element(data.begin(), data.end()) <= max_label);

    // first get mask of used labels
    thrust::device_vector<int> label_mask(max_label + 1, 0);
    thrust::scatter(thrust::constant_iterator<int>(1), thrust::constant_iterator<int>(1) + data.size(), data.begin(), label_mask.begin());

    // get map of original labels to consecutive ones
    thrust::device_vector<int> label_to_consecutive(max_label + 1);
    thrust::exclusive_scan(label_mask.begin(), label_mask.end(), label_to_consecutive.begin());

    // apply compressed label map
    thrust::device_vector<int> result(data.size(), 0);
    thrust::gather(data.begin(), data.end(), label_to_consecutive.begin(), result.begin());

    return result;
}


thrust::device_vector<float> per_cc_cost(cusparseHandle_t handle, const dCOO& A, const dCOO& C, const thrust::device_vector<int>& node_mapping, const int nr_ccs)
{
    thrust::device_vector<float> d = A.diagonal(handle);
    return d;
}

struct is_negative
{
    __host__ __device__
        bool operator()(const float x)
        {
            return x < 0.0;
        }
};
bool has_bad_contractions(cusparseHandle_t handle, const dCOO& A)
{
    const thrust::device_vector<float> d = A.diagonal(handle);
    return thrust::count_if(d.begin(), d.end(), is_negative()) > 0;
}

struct remove_bad_contraction_edges_func
{
    const int nr_ccs;
    const float* cc_cost;
    __host__ __device__
        int operator()(thrust::tuple<int,int> t)
        {
            const int cc = thrust::get<0>(t);
            const int node_id = thrust::get<1>(t);
            if (cc_cost[cc] > 0.0)
                return cc;
            return node_id + nr_ccs;
        }
};

thrust::device_vector<int> discard_bad_contractions(cusparseHandle_t handle, const dCOO& contracted_A, const thrust::device_vector<int>& node_mapping)
{
    MEASURE_CUMULATIVE_FUNCTION_EXECUTION_TIME;
    int nr_ccs = *thrust::max_element(node_mapping.begin(), node_mapping.end()) + 1;
    // for each component, how profitable was it to contract it?
    const thrust::device_vector<float> d = contracted_A.diagonal(handle);

    remove_bad_contraction_edges_func func({nr_ccs, thrust::raw_pointer_cast(d.data())}); 

    thrust::device_vector<int> good_node_mapping = node_mapping;
    thrust::device_vector<int> input_node_ids(node_mapping.size());
    thrust::sequence(input_node_ids.begin(), input_node_ids.end(), 0);

    auto first = thrust::make_zip_iterator(thrust::make_tuple(good_node_mapping.begin(), input_node_ids.begin()));
    auto last = thrust::make_zip_iterator(thrust::make_tuple(good_node_mapping.end(), input_node_ids.end()));
    thrust::transform(first, last, good_node_mapping.begin(), func);
    
    good_node_mapping = compress_label_sequence(good_node_mapping, nr_ccs + node_mapping.size());
    assert(*thrust::max_element(good_node_mapping.begin(), good_node_mapping.end()) > nr_ccs);
    return good_node_mapping;
}


struct negative_edge_indicator_func
{
    const float w = 0.0;
    __host__ __device__
        bool operator()(const thrust::tuple<int,int,float> t)
        {
            // if(thrust::get<0>(t) <= thrust::get<1>(t)) // we only want one representative
            //     return true;
            if(thrust::get<2>(t) <= w)
                return true;
            return false;
        }
};

struct edge_comparator_func {
    __host__ __device__
        inline bool operator()(const thrust::tuple<int, int, float>& a, const thrust::tuple<int, int, float>& b)
        {
            return thrust::get<2>(a) > thrust::get<2>(b);
        } 
};

std::tuple<thrust::device_vector<int>, int> contraction_mapping_by_sorting(cusparseHandle_t handle, dCOO& A, const float retain_ratio)
{
    thrust::device_vector<int> row_ids = A.get_row_ids();
    thrust::device_vector<int> col_ids = A.get_col_ids();
    thrust::device_vector<float> data = A.get_data();

    auto first = thrust::make_zip_iterator(thrust::make_tuple(col_ids.begin(), row_ids.begin(), data.begin()));
    auto last = thrust::make_zip_iterator(thrust::make_tuple(col_ids.end(), row_ids.end(), data.end()));

    const double smallest_edge_weight = *thrust::min_element(data.begin(), data.end());
    const double largest_edge_weight = *thrust::max_element(data.begin(), data.end());
    const float mid_edge_weight = retain_ratio * largest_edge_weight;

    auto new_last = thrust::remove_if(first, last, negative_edge_indicator_func({mid_edge_weight}));
    const size_t nr_remaining_edges = std::distance(first, new_last);
    col_ids.resize(nr_remaining_edges);
    row_ids.resize(nr_remaining_edges);
    if (nr_remaining_edges == 0)
        return {thrust::device_vector<int>(0), 0};

    /*
    if(max_contractions < nr_positive_edges)
    {
        auto first = thrust::make_zip_iterator(thrust::make_tuple(col_ids.begin(), row_ids.begin(), data.begin()));
        auto last = thrust::make_zip_iterator(thrust::make_tuple(col_ids.end(), row_ids.end(), data.end()));
        thrust::sort(first, last, edge_comparator_func()); // TODO: faster through sort by keys?

        col_ids.resize(max_contractions);
        row_ids.resize(max_contractions);
        data.resize(max_contractions);
    }
    */

    // add reverse edges
    std::tie(row_ids, col_ids) = to_undirected(row_ids.begin(), row_ids.end(), col_ids.begin(), col_ids.end());

    assert(col_ids.size() == row_ids.size());
    coo_sorting(handle, col_ids, row_ids);
    thrust::device_vector<int> row_offsets = dCOO::compute_row_offsets(handle, A.rows(), col_ids, row_ids);

    thrust::device_vector<int> cc_labels(max(A.rows(), A.cols()));
    computeCC_gpu(max(A.rows(), A.cols()), col_ids.size(), 
            thrust::raw_pointer_cast(row_offsets.data()), thrust::raw_pointer_cast(col_ids.data()), 
            thrust::raw_pointer_cast(cc_labels.data()), get_cuda_device());

    thrust::device_vector<int> node_mapping = compress_label_sequence(cc_labels, cc_labels.size() - 1);
    const int nr_ccs = *thrust::max_element(node_mapping.begin(), node_mapping.end()) + 1;

    assert(nr_ccs < max(A.rows(), A.cols()));

    return {node_mapping, row_ids.size()};

}

std::tuple<thrust::device_vector<int>, int> contraction_mapping_by_maximum_matching(cusparseHandle_t handle, dCOO& A)
{
    MEASURE_CUMULATIVE_FUNCTION_EXECUTION_TIME;
    MEASURE_FUNCTION_EXECUTION_TIME;
    thrust::device_vector<int> node_mapping;
    int nr_matched_edges;
    std::tie(node_mapping, nr_matched_edges) = filter_edges_by_matching_vertex_based(handle, A.export_undirected());
    return {compress_label_sequence(node_mapping, node_mapping.size() - 1), nr_matched_edges};
}

std::vector<int> parallel_gaec_cuda(dCOO& A)
{
    MEASURE_CUMULATIVE_FUNCTION_EXECUTION_TIME;
    cusparseHandle_t handle;
    checkCuSparseError(cusparseCreate(&handle), "cusparse init failed");

    const double initial_lb = A.sum();
    std::cout << "initial energy = " << initial_lb << "\n";

    thrust::device_vector<int> node_mapping(A.rows());
    thrust::sequence(node_mapping.begin(), node_mapping.end());
    double contract_ratio = 0.5;

    bool try_edges_to_contract_by_maximum_matching = true;
    // assert(A.rows() == A.cols());
    
    for(size_t iter=0;; ++iter)
    {
        //const size_t nr_edges_to_contract = std::max(size_t(1), size_t(A.rows() * contract_ratio));
        // if (iter > 0)
        // {
        //     dCOO A_dir = A.export_directed(handle);
        //     parallel_small_cycle_packing_cuda(handle, A_dir, 1, 0);
        //     A = A_dir.export_undirected(handle); //TODO: just replace data ?
        // }
        thrust::device_vector<int> cur_node_mapping;
        int nr_edges_to_contract;
        if(try_edges_to_contract_by_maximum_matching)
        {
            std::tie(cur_node_mapping, nr_edges_to_contract) = contraction_mapping_by_maximum_matching(handle, A);
            if(nr_edges_to_contract < A.rows()*0.1)
            {
                std::cout << "# edges to contract = " << nr_edges_to_contract << ", # vertices = " << A.rows() << "\n";
                std::cout << "switching to sorting based contraction edge selection\n";
                try_edges_to_contract_by_maximum_matching = false;    
            }
        }
        if(!try_edges_to_contract_by_maximum_matching)
            std::tie(cur_node_mapping, nr_edges_to_contract) = contraction_mapping_by_sorting(handle, A, contract_ratio);


        //std::cout << "iter " << iter << ", edge contraction ratio = " << contract_ratio << ", # edges to contract request " << nr_edges_to_contract << ", # nr edges to contract provided = " << contract_cols.size() << "\n";

        if(nr_edges_to_contract == 0)
        {
            std::cout << "# iterations = " << iter << "\n";
            break;
        }

        dCOO new_A = A.contract_cuda(handle, cur_node_mapping);
        std::cout << "original A size " << A.cols() << "x" << A.rows() << "\n";
        std::cout << "contracted A size " << new_A.cols() << "x" << new_A.rows() << "\n";
        assert(new_A.cols() < A.cols());

        const thrust::device_vector<float> diagonal = new_A.diagonal(handle);
        const float energy_reduction = thrust::reduce(diagonal.begin(), diagonal.end());
        std::cout << "energy reduction " << energy_reduction << "\n";
        //if(energy_reduction < 0.0)
        if(has_bad_contractions(handle, new_A))
        {
            if(!try_edges_to_contract_by_maximum_matching)
                contract_ratio *= 2.0; 
            //contract_ratio = std::max(contract_ratio, 0.005);
            // get contraction edges of the components which
            int nr_ccs = *thrust::max_element(cur_node_mapping.begin(), cur_node_mapping.end()) + 1;
            cur_node_mapping = discard_bad_contractions(handle, new_A, cur_node_mapping);
            int good_nr_ccs = *thrust::max_element(cur_node_mapping.begin(), cur_node_mapping.end()) + 1;
            assert(good_nr_ccs > nr_ccs);
            std::cout << "Reverted from " << nr_ccs << " connected components to " << good_nr_ccs << "\n";
            if (good_nr_ccs == cur_node_mapping.size()) 
                break;
            
            new_A = A.contract_cuda(handle, cur_node_mapping);
            assert(!has_bad_contractions(handle, new_A));
        }
        else
        {
            if(!try_edges_to_contract_by_maximum_matching)
            {
                contract_ratio *= 0.5;//1.3;
                contract_ratio = std::min(contract_ratio, 0.35);
            }
        }

        thrust::swap(A,new_A);
        A.remove_diagonal(handle);
        std::cout << "energy after iteration " << iter << ": " << A.sum() << ", #components = " << A.cols() << "\n";
        thrust::gather(node_mapping.begin(), node_mapping.end(), cur_node_mapping.begin(), node_mapping.begin());
    }

    const double lb = A.sum();
    std::cout << "final energy = " << lb << "\n";

    cusparseDestroy(handle);
    std::vector<int> h_node_mapping(node_mapping.size());
    thrust::copy(node_mapping.begin(), node_mapping.end(), h_node_mapping.begin());
    return h_node_mapping;
}

void print_obj_original(const std::vector<int>& h_node_mapping, const std::vector<int>& i, const std::vector<int>& j, const std::vector<float>& costs)
{
    double obj = 0;
    const int nr_edges = costs.size();
    for (int e = 0; e < nr_edges; e++)
    {
        const int e1 = i[e];
        const int e2 = j[e];
        const float c = costs[e];
        if (h_node_mapping[e1] != h_node_mapping[e2])
            obj += c;
    }
    std::cout<<"Cost w.r.t original objective: "<<obj<<std::endl;
}

std::vector<int> parallel_gaec_cuda(const std::vector<int>& i, const std::vector<int>& j, const std::vector<float>& costs)
{
    const int cuda_device = get_cuda_device();
    cudaSetDevice(cuda_device);
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, cuda_device);
    std::cout << "Going to use " << prop.name << " " << prop.major << "." << prop.minor << ", device number " << cuda_device << "\n";

    // thrust::device_vector<int> i_un, j_un;
    // thrust::device_vector<float> costs_un;
    // std::tie(i_un, j_un, costs_un) = to_undirected(i.begin(), i.end(), j.begin(), j.end(), costs.begin(), costs.end());
    // dCOO A(std::move(i_un), std::move(j_un), std::move(costs_un));
    dCOO A(i.begin(), i.end(), j.begin(), j.end(), costs.begin(), costs.end());

    const std::vector<int> h_node_mapping = parallel_gaec_cuda(A);
    
    return h_node_mapping;
}
