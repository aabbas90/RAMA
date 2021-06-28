#include <cuda_runtime.h>
#include "icp.h"
#include <thrust/reduce.h>
#include <stdio.h>
#include "time_measure_util.h"
#include<set>
static const float tol = 1e-3;

// https://stackoverflow.com/questions/62091548/atomiccas-for-bool-implementation
static __inline__ __device__ bool atomicCAS(bool *address, bool compare, bool val)
{
    unsigned long long addr = (unsigned long long)address;
    unsigned pos = addr & 3;  // byte position within the int
    int *int_addr = (int *)(addr - pos);  // int-aligned address
    int old = *int_addr, assumed, ival;

    bool current_value;

    do
    {
        current_value = (bool)(old & ((0xFFU) << (8 * pos)));

        if(current_value != compare) // If we expected that bool to be different, then
            break; // stop trying to update it and just return it's current value

        assumed = old;
        if(val)
            ival = old | (1 << (8 * pos));
        else
            ival = old & (~((0xFFU) << (8 * pos)));
        old = atomicCAS(int_addr, assumed, ival);
    } while(assumed != old);

    return current_value;
}

__global__ void initialize(const int num_edges, const int* const __restrict__ e_row_ids, const int* const __restrict__ e_col_ids, const float* const __restrict__ e_values, 
                        int* const __restrict__ v_dist, int* const __restrict__ v_seed_edge, int* const __restrict__ v_parent_edge, 
                        bool* const __restrict__ e_valid_seeds, const bool* const __restrict__ e_used, 
                        bool* const __restrict__ still_running)
{
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int num_threads = blockDim.x * gridDim.x;

    for (int edge = tid; edge < num_edges; edge += num_threads) 
    {
        // printf("Hello from block %d, thread %d tid %d edge %d\n", blockIdx.x, threadIdx.x, tid, edge);
        if (e_values[edge] < -tol && !e_used[edge]) 
        {
            // printf("Neg edge block %d, thread %d, edge %d\n", blockIdx.x, threadIdx.x, edge);
            const int from_vertex = e_row_ids[edge];
            v_dist[from_vertex] = 0;
            
            // If from_vertex is part of more than one negative edge, then make it part of the edge with highest index
            atomicMax(&v_seed_edge[from_vertex], edge); 
            if (v_seed_edge[from_vertex] == edge) // winner thread.
            {
                // printf("Hello from block %d, thread %d, edge %d, propagating\n", blockIdx.x, threadIdx.x, edge);
                v_parent_edge[from_vertex] = edge;
                //TODO: Size of following array can be reduced to only contain negative edge indices.
                e_valid_seeds[edge] = true;
                *still_running = true;
            }
        }
        __syncthreads();
    }
}

__device__ void propagate(const int itr, const int edge, const int src_v, const int dst_v, const int src_seed_edge, const int dst_seed_edge, const float e_value, 
                        int* const __restrict__ v_seed_edge, int* const __restrict__ v_dist, int* const __restrict__ v_parent_edge, 
                        bool* const __restrict__ e_valid_seeds, const bool* const __restrict__ e_used, 
                        bool* const __restrict__ still_running)
{

    if (!e_valid_seeds[src_seed_edge]) // || e_used[dst_seed_edge])
        return; // Either the path is cut-off in which case expanding is useless, or the path was already explored and cycle was found in previous episode.

    atomicMax(&v_seed_edge[dst_v], src_seed_edge);

    if (src_seed_edge == v_seed_edge[dst_v]) // winner thread continues onward, 
    {
        e_valid_seeds[dst_seed_edge] = false; // Overridden by a higher priority path. 
        v_parent_edge[dst_v] = edge;
        v_dist[dst_v] = itr + 1;
        *still_running = true;
    }
}

__global__ void expand(const int iteration, const int num_edges, const int* const __restrict__ e_row_ids, const int* const __restrict__ e_col_ids, const float* const __restrict__ e_values, 
                    int* const __restrict__ v_dist, int* const __restrict__ v_seed_edge, int* const __restrict__ v_parent_edge, 
                    bool* const __restrict__ e_valid_seeds, const bool* const __restrict__ e_used, 
                    bool* const __restrict__ still_running)
{
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int num_threads = blockDim.x * gridDim.x;
    for (int edge = tid; edge < num_edges; edge += num_threads) 
    {
        float e_value = e_values[edge];
        if (e_value > tol) 
        {
            const int n1 = e_row_ids[edge];
            const int n2 = e_col_ids[edge];
            const int n1_seed_edge = v_seed_edge[n1];
            const int n2_seed_edge = v_seed_edge[n2];
            
            // Propagate from n1 to n2 if:
            // 1. n1 is at frontier.
            // 2. n2 is unmarked (in which case n2_seed_edge would be -1) OR n2 is marked with a lower priority path.
            if (v_dist[n1] == iteration && n1_seed_edge > n2_seed_edge)
                propagate(iteration, edge, n1, n2, n1_seed_edge, n2_seed_edge, e_value, v_seed_edge, v_dist, v_parent_edge, e_valid_seeds, e_used, still_running);
            
            // Consider edge in opposite direction (n2 to n1) if previous attempt failed.
            else if (v_dist[n2] == iteration && n2_seed_edge > n1_seed_edge)
                propagate(iteration, edge, n2, n1, n2_seed_edge, n1_seed_edge, e_value, v_seed_edge, v_dist, v_parent_edge, e_valid_seeds, e_used, still_running);
            
            // When two ends of a cycle meet then n1_seed_edge = n2_seed_edge so no further propagation would happen.
        }
        __syncthreads();
    }
}


__device__ void print_cycle(int edge, int cycle_length, const int* const __restrict__ e_row_ids, const int* const __restrict__ e_col_ids, float* const __restrict__ e_values, 
    const int* const __restrict__ v_seed_edge, const int* const __restrict__ v_parent_edge, 
    bool* const __restrict__ e_valid_seeds, bool* const __restrict__ e_used)
{
    int to_vertex = e_col_ids[edge];
    int next_edge = v_parent_edge[to_vertex];
    for (int e = 0; e != cycle_length; ++e)
    {
        printf("edge: %d, next_edge: %d, seed_edge: %d, hop: %d, vertex: %d \n", edge, next_edge, v_seed_edge[to_vertex], e, to_vertex);
        assert(to_vertex != e_col_ids[next_edge] || to_vertex != e_row_ids[next_edge]);
        to_vertex = e_col_ids[next_edge] == to_vertex ? e_row_ids[next_edge] : e_col_ids[next_edge];
        next_edge = v_parent_edge[to_vertex];
    }

}

__global__ void reparameterize(int num_edges, int cycle_length, const int* const __restrict__ e_row_ids, const int* const __restrict__ e_col_ids, float* const __restrict__ e_values, 
    const int* const __restrict__ v_seed_edge, const int* const __restrict__ v_parent_edge, 
    bool* const __restrict__ e_valid_seeds, bool* const __restrict__ e_used, int* const __restrict__ num_cycles_packed)
{
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int num_threads = blockDim.x * gridDim.x;
    for (int edge = tid; edge < num_edges; edge += num_threads) 
    {
        const int from_vertex = e_row_ids[edge];
        int to_vertex = e_col_ids[edge];
        const int seed_edge = v_seed_edge[from_vertex];
        // seed is valid, edge is negative, both ends agree (valid cycle), not overriden, not already reparameterized.
        if (seed_edge >=0 && edge == seed_edge && seed_edge == v_seed_edge[to_vertex] && e_valid_seeds[seed_edge] && !e_used[seed_edge])
        {
            assert(e_values[seed_edge] < 0);
            bool old_value = atomicCAS(&e_valid_seeds[seed_edge], true, false);
            if (old_value) 
            {
                e_used[seed_edge] = true;
                bool invalid = false;
                float message = -e_values[seed_edge];
                assert(message >= 0);
                int next_edge = v_parent_edge[to_vertex];
                assert(next_edge >= 0);
                for (int e = 0; e != cycle_length - 1; ++e)
                {
                    //DEBUG:
                    // assert(v_seed_edge[to_vertex] == seed_edge);
                    if (v_seed_edge[to_vertex] != seed_edge || e_values[next_edge] <= 0 || next_edge == seed_edge)
                    {
                        invalid = true;
                        e_used[seed_edge] = false;
                        break;
                    }
                    
                    // assert(v_seed_edge[to_vertex] == seed_edge);
                    // assert(e_values[next_edge] >= 0);
                    message = min(e_values[next_edge], message);
                    to_vertex = e_col_ids[next_edge] == to_vertex ? e_row_ids[next_edge] : e_col_ids[next_edge];
                    next_edge = v_parent_edge[to_vertex];
                    assert(next_edge >= 0);
                }
                if (invalid || to_vertex != from_vertex)
                    continue;
                to_vertex = e_col_ids[edge];
                next_edge = v_parent_edge[to_vertex];
                assert(message >= 0);
                e_values[edge] += message; 
                atomicAdd(&num_cycles_packed[0], 1); // TODO: For debugging info, should remove during production.
                for (int e = 0; e != cycle_length - 1; ++e)
                {
                    assert(e_values[next_edge] >= 0);
                    assert(message >= 0);
                    if (e_values[next_edge] < message)
                    {
                        print_cycle(edge, cycle_length, e_row_ids, e_col_ids, e_values, 
                            v_seed_edge, v_parent_edge, 
                            e_valid_seeds, e_used);
                    }
                    assert(e_values[next_edge] >= message);

                    e_values[next_edge] -= message;
                    to_vertex = e_col_ids[next_edge] == to_vertex ? e_row_ids[next_edge] : e_col_ids[next_edge];
                    next_edge = v_parent_edge[to_vertex];
                }
            }
        }
        __syncthreads();
    }
}

std::set<int> find_cycle_edges(const int cycle_length, const int seed_edge, 
                            const std::vector<int>& row_ids, const std::vector<int>& col_ids, 
                            const std::vector<int>& v_parent_edge, const std::vector<int>& v_seed_edge)
{
    std::set<int> positive_edges;
    int start_vertex = row_ids[seed_edge];
    int end_vertex = col_ids[seed_edge];
    if (v_parent_edge[end_vertex] == seed_edge)
    {
        int temp = start_vertex;
        start_vertex = end_vertex;
        end_vertex = temp;
    }
    if (v_seed_edge[end_vertex] != seed_edge || v_parent_edge[start_vertex] != seed_edge)
        return positive_edges;

    for (int i = 0; i < cycle_length - 1; i++)
    {
        int next_edge = v_parent_edge[end_vertex];
        assert(next_edge != seed_edge);
        assert(positive_edges.find(next_edge) == positive_edges.end());
        positive_edges.insert(next_edge);
        end_vertex = col_ids[next_edge] == end_vertex ? row_ids[next_edge] : col_ids[next_edge];
    }
    assert(end_vertex == start_vertex);
    return positive_edges;
}

void check_detected_cycles(int cycle_length, const thrust::device_vector<int>& row_ids, const thrust::device_vector<int>& col_ids, const thrust::device_vector<float>& costs,
    const thrust::device_vector<float>& costs_reparam, const thrust::device_vector<int>& v_parent_edge, const thrust::device_vector<int>& v_dist, 
    const thrust::device_vector<bool>& e_used, const thrust::device_vector<bool>& prev_e_used, 
    const thrust::device_vector<int>& v_seed_edge, const thrust::device_vector<bool>& e_valid_seeds)
{
    std::vector<int> row_ids_h(row_ids.size());
    thrust::copy(row_ids.begin(), row_ids.end(), row_ids_h.begin());
    std::vector<int> col_ids_h(col_ids.size());
    thrust::copy(col_ids.begin(), col_ids.end(), col_ids_h.begin());
    std::vector<int> costs_h(costs.size());
    thrust::copy(costs.begin(), costs.end(), costs_h.begin());
    std::vector<int> costs_reparam_h(costs_reparam.size());
    thrust::copy(costs_reparam.begin(), costs_reparam.end(), costs_reparam_h.begin());
    std::vector<int> v_parent_edge_h(v_parent_edge.size());
    thrust::copy(v_parent_edge.begin(), v_parent_edge.end(), v_parent_edge_h.begin());
    std::vector<int> v_seed_edge_h(v_seed_edge.size());
    thrust::copy(v_seed_edge.begin(), v_seed_edge.end(), v_seed_edge_h.begin());
    std::vector<int> v_dist_h(v_dist.size());
    thrust::copy(v_dist.begin(), v_dist.end(), v_dist_h.begin());
    std::vector<bool> e_used_h(e_used.size());
    thrust::copy(e_used.begin(), e_used.end(), e_used_h.begin());
    std::vector<bool> prev_e_used_h(prev_e_used.size());
    thrust::copy(prev_e_used.begin(), prev_e_used.end(), prev_e_used_h.begin());
    std::vector<bool> e_valid_seeds_h(e_valid_seeds.size());
    thrust::copy(e_valid_seeds.begin(), e_valid_seeds.end(), e_valid_seeds_h.begin());
    std::vector<int> e_count(e_used_h.size(), 0);

    for (int e = 0; e < e_used_h.size(); e++)
    {
        if (prev_e_used_h[e] || costs_h[e] >= 0 || !e_used_h[e] || !e_valid_seeds_h[e])
            continue;
        
        std::set<int> pos_edges = find_cycle_edges(cycle_length, e, row_ids_h, col_ids_h, v_parent_edge_h, v_seed_edge_h);
        for (auto p: pos_edges)
        {
            assert(e_count[p] == 0);
            e_count[p]++;
        }
    }
}

// row_ids, col_ids, values should be directed thus containing same number of elements as in original problem.
std::tuple<thrust::device_vector<int>, thrust::device_vector<int>, thrust::device_vector<float>> parallel_cycle_packing_cuda(
    const thrust::device_vector<int>& row_ids, const thrust::device_vector<int>& col_ids, const thrust::device_vector<float>& costs,
    const int max_cycle_length, const int max_tries)
{
    // thrust::host_vector<float> costs_h = costs;
    MEASURE_FUNCTION_EXECUTION_TIME;

    int num_nodes = std::max(*thrust::max_element(row_ids.begin(), row_ids.end()), *thrust::max_element(col_ids.begin(), col_ids.end())) + 1;
    int num_edges = row_ids.size();
    thrust::device_vector<float> costs_reparam = costs;
    thrust::device_vector<int> v_seed_edge(num_nodes);
    thrust::device_vector<int> v_dist(num_nodes);
    thrust::device_vector<int> v_parent_edge(num_nodes);
    thrust::device_vector<bool> e_valid_seeds(num_edges);
    thrust::device_vector<bool> e_used(num_edges, false);
    thrust::device_vector<bool> still_running(1, false);
    thrust::device_vector<int> num_cycles_packed(1, 0);

    //DEBUG: 
    // thrust::device_vector<bool> prev_e_used(num_edges, false);

    int threadCount = 256;
    int blockCount = ceil(num_edges / (float) threadCount);
    int l = 3;

    int try_idx = 0;
    while(l <= max_cycle_length)
    {
        thrust::fill(thrust::device, v_seed_edge.begin(), v_seed_edge.end(), -1);
        thrust::fill(thrust::device, v_dist.begin(), v_dist.end(), -1);
        thrust::fill(thrust::device, v_parent_edge.begin(), v_parent_edge.end(), -1);
        thrust::fill(thrust::device, e_valid_seeds.begin(), e_valid_seeds.end(), false);
        thrust::fill(thrust::device, still_running.begin(), still_running.end(), false);

        initialize<<<blockCount, threadCount>>>(num_edges, 
                                            thrust::raw_pointer_cast(row_ids.data()), 
                                            thrust::raw_pointer_cast(col_ids.data()), 
                                            thrust::raw_pointer_cast(costs_reparam.data()), 
                                            thrust::raw_pointer_cast(v_dist.data()), 
                                            thrust::raw_pointer_cast(v_seed_edge.data()), 
                                            thrust::raw_pointer_cast(v_parent_edge.data()), 
                                            thrust::raw_pointer_cast(e_valid_seeds.data()), 
                                            thrust::raw_pointer_cast(e_used.data()), 
                                            thrust::raw_pointer_cast(still_running.data()));
        bool still_running_h = still_running[0];
        for (int itr = 0; itr < l - 1 && still_running_h; itr++)
        {   
            expand<<<blockCount, threadCount>>>(itr, num_edges, 
                                            thrust::raw_pointer_cast(row_ids.data()),
                                            thrust::raw_pointer_cast(col_ids.data()),
                                            thrust::raw_pointer_cast(costs_reparam.data()),
                                            thrust::raw_pointer_cast(v_dist.data()),
                                            thrust::raw_pointer_cast(v_seed_edge.data()),
                                            thrust::raw_pointer_cast(v_parent_edge.data()), 
                                            thrust::raw_pointer_cast(e_valid_seeds.data()),
                                            thrust::raw_pointer_cast(e_used.data()),
                                            thrust::raw_pointer_cast(still_running.data()));
            still_running_h = still_running[0];
        }

        try_idx++;
        if (!still_running_h || try_idx > max_tries)
        {
            thrust::fill(thrust::device, e_used.begin(), e_used.end(), false);
            thrust::fill(thrust::device, num_cycles_packed.begin(), num_cycles_packed.end(), 0);
            l++;
            try_idx = 0;
            continue;
        }
        reparameterize<<<blockCount, threadCount>>>(num_edges, l,
                                            thrust::raw_pointer_cast(row_ids.data()), 
                                            thrust::raw_pointer_cast(col_ids.data()), 
                                            thrust::raw_pointer_cast(costs_reparam.data()), 
                                            thrust::raw_pointer_cast(v_seed_edge.data()), 
                                            thrust::raw_pointer_cast(v_parent_edge.data()), 
                                            thrust::raw_pointer_cast(e_valid_seeds.data()), 
                                            thrust::raw_pointer_cast(e_used.data()), 
                                            thrust::raw_pointer_cast(num_cycles_packed.data()));

        thrust::transform(e_used.begin(), e_used.end(), e_valid_seeds.begin(), e_used.begin(), thrust::maximum<bool>());
        std::cout<<"cycle length: "<<l<<", cumulative # used -ive edges: "<<thrust::reduce(e_used.begin(), e_used.end(), 0)<<" cumulative # cycles packed: "<<num_cycles_packed[0]<<std::endl;

        // thrust::copy(costs_reparam.begin(), costs_reparam.end(), std::ostream_iterator<float>(std::cout, " "));
        // std::cout<<"\n";

        // check_detected_cycles(l, row_ids, col_ids, costs, costs_reparam, v_parent_edge, v_dist, e_used, prev_e_used, v_seed_edge, e_valid_seeds);
        // prev_e_used = e_used;
    }

    return {row_ids, col_ids, costs_reparam};
}