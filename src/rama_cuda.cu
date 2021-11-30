#include <cuda_runtime.h>
#include "union_find.hxx"
#include "time_measure_util.h"
#include <algorithm>
#include <cstdlib>
#include "ECLgraph.h"
#include <thrust/transform_scan.h>
#include <thrust/transform.h>
#include "maximum_matching_vertex_based.h"
#include "maximum_matching_thrust.h"
#include "multicut_solver_options.h"
#include "dual_solver.h"
#include "edge_contractions_woc.h"
#include "rama_utils.h"

struct is_negative
{
    __host__ __device__
        bool operator()(const float x)
        {
            return x < 0.0;
        }
};
bool has_bad_contractions(const dCOO& A)
{
    const thrust::device_vector<float> d = A.diagonal();
    return thrust::count_if(d.begin(), d.end(), is_negative()) > 0;
}

std::tuple<thrust::device_vector<int>, int> contraction_mapping_by_maximum_matching(dCOO& A, const float mean_multiplier_mm, const bool verbose = true)
{
    MEASURE_CUMULATIVE_FUNCTION_EXECUTION_TIME;
    thrust::device_vector<int> node_mapping;
    int nr_matched_edges;
    std::tie(node_mapping, nr_matched_edges) = filter_edges_by_matching_vertex_based(A.export_undirected(), mean_multiplier_mm, verbose);
    // std::tie(node_mapping, nr_matched_edges) = filter_edges_by_matching_thrust(A, mean_multiplier_mm, verbose);
    return {compress_label_sequence(node_mapping, node_mapping.size() - 1), nr_matched_edges};
}

std::tuple<thrust::device_vector<int>, double, std::vector<std::vector<int>> > rama_cuda(dCOO& A, const multicut_solver_options& opts)
{
    MEASURE_CUMULATIVE_FUNCTION_EXECUTION_TIME;
    std::chrono::steady_clock::time_point begin = std::chrono::steady_clock::now();

    assert(A.is_directed());

    const double final_lb = dual_solver(A, opts.max_cycle_length_lb, opts.num_dual_itr_lb, opts.tri_memory_factor, opts.num_outer_itr_dual, 1e-4, opts.verbose);

    if (opts.verbose)
        std::cout << "initial energy = " << A.sum() << "\n";

    thrust::device_vector<int> node_mapping(A.max_dim());
    thrust::sequence(node_mapping.begin(), node_mapping.end());

    std::vector<std::vector<int>> timeline;

    if (opts.only_compute_lb)
        return {std::vector<int>(), final_lb, timeline};
        
    bool try_edges_to_contract_by_maximum_matching = true;
    if (opts.matching_thresh_crossover_ratio > 1.0)
        try_edges_to_contract_by_maximum_matching = false;
    
    for(size_t iter=0; A.nnz() > 0; ++iter)
    {
        if (iter > 0)
        {
            dual_solver(A, opts.max_cycle_length_primal, opts.num_dual_itr_primal, 1.0, 1, 1e-4, opts.verbose);
        }
        thrust::device_vector<int> cur_node_mapping;
        int nr_edges_to_contract;
        if(try_edges_to_contract_by_maximum_matching)
        {
            std::tie(cur_node_mapping, nr_edges_to_contract) = contraction_mapping_by_maximum_matching(A, opts.mean_multiplier_mm, opts.verbose);
            if(nr_edges_to_contract < A.rows() * opts.matching_thresh_crossover_ratio)
            {
                if (opts.verbose)
                {
                    std::cout << "# edges to contract = " << nr_edges_to_contract << ", # vertices = " << A.rows() << "\n";
                    std::cout << "switching to MST based contraction edge selection\n";
                }
                try_edges_to_contract_by_maximum_matching = false;    
            }
        }
        else
        {
            edge_contractions_woc c_mapper(A, opts.verbose);
            std::tie(cur_node_mapping, nr_edges_to_contract) = c_mapper.find_contraction_mapping();
        }

        if(nr_edges_to_contract == 0)
        {
            if (opts.verbose)
                std::cout << "# iterations = " << iter << "\n";
            break;
        }

        dCOO new_A = A.contract_cuda(cur_node_mapping);
        if (opts.verbose)
        {
            std::cout << "original A size " << A.cols() << "x" << A.rows() << "\n";
            std::cout << "contracted A size " << new_A.cols() << "x" << new_A.rows() << "\n";
        }
        assert(new_A.cols() < A.cols());

        if (opts.verbose)
        {
            const thrust::device_vector<float> diagonal = new_A.diagonal();
            const float energy_reduction = thrust::reduce(diagonal.begin(), diagonal.end());
            std::cout << "energy reduction " << energy_reduction << "\n";
        }
        if(has_bad_contractions(new_A))
            throw std::runtime_error("Found bad contractions");

        thrust::swap(A, new_A);
        A.remove_diagonal();
        if (opts.verbose)
            std::cout << "energy after iteration " << iter << ": " << A.sum() << ", #components = " << A.cols() << "\n";
        thrust::gather(node_mapping.begin(), node_mapping.end(), cur_node_mapping.begin(), node_mapping.begin());
        if (opts.dump_timeline)
        {
            std::vector<int> current_timeline(node_mapping.size());
            thrust::copy(node_mapping.begin(), node_mapping.end(), current_timeline.begin());
            timeline.push_back(current_timeline);
        }
        if (opts.max_time_sec >= 0)
        {
            std::chrono::steady_clock::time_point end = std::chrono::steady_clock::now();
            auto time = std::chrono::duration_cast<std::chrono::seconds>(end - begin).count();
            if (time > opts.max_time_sec)
                break;
        }
    }

    if (opts.verbose)
        std::cout << "final energy = " << A.sum() << "\n";

    return {node_mapping, final_lb, timeline};
}

std::tuple<std::vector<int>, double, int, std::vector<std::vector<int>> > rama_cuda(const std::vector<int>& i, const std::vector<int>& j, const std::vector<float>& costs, const multicut_solver_options& opts, const bool contains_duplicate_edges)
{
    const int cuda_device = get_cuda_device();
    cudaSetDevice(cuda_device);
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, cuda_device);
    if (opts.verbose)
        std::cout << "Going to use " << prop.name << " " << prop.major << "." << prop.minor << ", device number " << cuda_device << "\n";

    dCOO A(i.begin(), i.end(), j.begin(), j.end(), costs.begin(), costs.end(), true);
    if (contains_duplicate_edges)
    {
        thrust::device_vector<int> identity_mapping(A.max_dim());
        thrust::sequence(identity_mapping.begin(), identity_mapping.end());
        A = A.contract_cuda(identity_mapping); // Merge duplicate edges and sum the costs.
    }
    thrust::device_vector<int> node_mapping;
    double lb;
    std::vector<std::vector<int>> timeline;
    
    std::chrono::steady_clock::time_point start_time = std::chrono::steady_clock::now();
    std::tie(node_mapping, lb, timeline) = rama_cuda(A, opts);
    std::vector<int> h_node_mapping(node_mapping.size());
    thrust::copy(node_mapping.begin(), node_mapping.end(), h_node_mapping.begin());
    std::chrono::steady_clock::time_point end_time = std::chrono::steady_clock::now();
    int time_duration = std::chrono::duration_cast<std::chrono::milliseconds>(end_time - start_time).count();
    return {h_node_mapping, lb, time_duration, timeline};
}

std::tuple<thrust::device_vector<int>, double> rama_cuda(thrust::device_vector<int>&& i, thrust::device_vector<int>&& j, thrust::device_vector<float>&& costs, const multicut_solver_options& opts, const int device)
{
    cudaSetDevice(device);
    dCOO A(std::move(j), std::move(i), std::move(costs), true);
    if (contains_duplicate_edges)
    {
        thrust::device_vector<int> identity_mapping(A.max_dim());
        thrust::sequence(identity_mapping.begin(), identity_mapping.end());
        A = A.contract_cuda(identity_mapping); // Merge duplicate edges and sum the costs.
    }
    thrust::device_vector<int> node_mapping;
    double lb;
    std::vector<std::vector<int>> timeline;
    
    std::tie(node_mapping, lb, timeline) = rama_cuda(A, opts);
    return {node_mapping, lb};
}