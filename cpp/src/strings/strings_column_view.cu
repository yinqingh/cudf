/*
 * Copyright (c) 2019-2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cudf/strings/strings_column_view.hpp>
#include <cudf/utilities/error.hpp>

#include <thrust/transform.h>

namespace cudf
{

//
strings_column_view::strings_column_view( column_view strings_column )
    : column_view(strings_column)
{
    CUDF_EXPECTS( type().id()==STRING, "strings_column_view only supports strings");
}

column_view strings_column_view::parent() const
{
    return static_cast<column_view>(*this);
}

column_view strings_column_view::offsets() const
{
    CUDF_EXPECTS( num_children()>0, "strings column has no children" );
    return child(offsets_column_index);
}

column_view strings_column_view::chars() const
{
    CUDF_EXPECTS( num_children()>0, "strings column has no children" );
    return child(chars_column_index);
}

size_type strings_column_view::chars_size() const noexcept
{
    if( size()==0 )
        return 0;
    return chars().size();
}

namespace strings
{

std::pair<rmm::device_vector<char>, rmm::device_vector<size_type> >
    create_offsets( strings_column_view const& strings,
                    cudaStream_t stream,
                    rmm::mr::device_memory_resource* mr )
{
    size_type count = strings.size();
    const int32_t* d_offsets = strings.offsets().data<int32_t>() + strings.offset();
    int32_t first_offset = 0;
    CUDA_TRY(cudaMemcpyAsync( &first_offset, d_offsets, sizeof(int32_t), cudaMemcpyDeviceToHost, stream));
    rmm::device_vector<size_type> second(count+1);
    // normalize the offset values for the column offset
    thrust::transform( rmm::exec_policy(stream)->on(stream),
                       d_offsets, d_offsets + count + 1,
                       second.begin(),
                       [first_offset] __device__ (int32_t offset) { return static_cast<size_type>(offset - first_offset); } );
    // copy the chars column data
    int32_t bytes = 0; // last offset entry is the size in bytes
    CUDA_TRY(cudaMemcpyAsync( &bytes, d_offsets+count, sizeof(int32_t),
                              cudaMemcpyDeviceToHost, stream));
    bytes -= first_offset;
    const char* d_chars = strings.chars().data<char>() + first_offset;
    rmm::device_vector<char> first(bytes);
    CUDA_TRY(cudaMemcpyAsync( first.data().get(), d_chars, bytes,
                              cudaMemcpyDeviceToHost, stream));

    return std::make_pair(std::move(first), std::move(second));
}

} // namespace strings
} // namespace cudf
