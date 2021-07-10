#pragma once

#include <thrust/device_vector.h>
#include <cusparse.h>
#include "dCOO.h"

double parallel_small_cycle_packing_cuda(cusparseHandle_t handle, dCOO& A, const int max_tries_triangles, const int max_tries_quads);

std::tuple<double, dCOO> parallel_small_cycle_packing_cuda(const std::vector<int>& i, const std::vector<int>& j, const std::vector<float>& costs, const int max_tries_triangles, const int max_tries_quads);

double parallel_small_cycle_packing_cuda_lower_bound(const std::vector<int>& i, const std::vector<int>& j, const std::vector<float>& costs, const int max_tries_triangles, const int max_tries_quads);