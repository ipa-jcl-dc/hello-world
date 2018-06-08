
#include "data_types.hpp"
#include <thrust/device_ptr.h>
#include <thrust/scan.h>
    namespace Cuda{

/**
 *  kernelExtractPointCloud: extract TSDF point cloud from tsdf volume and color volume
 *  tsdf_volume: current depth image input
 *  color_map : current color image input
 *  tsdf_volume : output of tsdf volume
 *  volume_res: resolution of cube
 *  voxel_size: size of each voxel
 *	vertices : TSDF point output
 *  color : RGB information of points stored in the same TSDF size
 *  point_num : number of surface points
 */



__global__ void kernelPrintTSDF(const cv::cuda::PtrStepSz<float> tsdf_volume,const int volume_res,
		float* tsdf_float)
{
	//Get id of each thread in 2 dimensions
		 const int x = blockIdx.x * blockDim.x + threadIdx.x;
		 const int y = blockIdx.y * blockDim.y + threadIdx.y;
		 if(x>volume_res || y>volume_res)
		 	return;

		 for(int z =0;z<volume_res;z++)
		 {
			 int volume_idx = x * volume_res*volume_res + y * volume_res + z;
			 const float tsdf = tsdf_volume.ptr(z*volume_res+y)[x];
			 if(tsdf==0 ||tsdf<=-0.99f || tsdf>=0.99f)
						 continue;
			 tsdf_float[volume_idx] = tsdf;

		 }
}
//__global__ void kernelConvertToFloat()
__device__ __forceinline__ float dot(const float3& v1, const float3& v2)
             {
           return __fmaf_rn(v1.x, v2.x, __fmaf_rn(v1.y, v2.y, v1.z*v2.z));
             }
__device__ __forceinline__
                float norm(const float3& v)
            {
                    return sqrt(dot(v, v));
            }
__device__ __forceinline__ float3 normalized(const float3& v)
            {
                float3 result = make_float3(v.x * rsqrt(dot(v, v)),v.z * rsqrt(dot(v, v)),v.y * rsqrt(dot(v, v)));
                return result;
            }
 __global__ void kernelExtractPointCloud(const cv::cuda::PtrStepSz<float> tsdf_volume,
		    const cv::cuda::PtrStepSz<uchar3> color_volume,
			const cv::cuda::PtrStepSz<float> weight_volume,
			const int volume_res,
			const float voxel_size,
			cv::cuda::PtrStep<float3> vertices,
			cv::cuda::PtrStep<float3> normals,
			cv::cuda::PtrStep<uchar3> color,
			int* point_num,
			const float original_distance_x,
			const float original_distance_y,
			const float original_distance_z)
{
	 //Get id of each thread in 2 dimensions
	 const int x = blockIdx.x * blockDim.x + threadIdx.x;
	 const int y = blockIdx.y * blockDim.y + threadIdx.y;
	 if(x>volume_res || y>volume_res)
	 	return;

	 for(int z =0;z<volume_res;z++)
	 {
		 //if(color_volume.ptr(z * volume_res + y)[x].z !=0)
		 // printf("%d \n",color_volume.ptr(z * volume_res + y)[x].z);
		 const float tsdf = tsdf_volume.ptr(z*volume_res+y)[x];
		 if(tsdf==0 ||tsdf<=-0.99f || tsdf>=0.99f)
			 continue;
		 //Get neighbor pixels of current tsdf index in x,y,z axis
		 float tsdf_x = tsdf_volume.ptr(z*volume_res+y)[x+1];
		 float tsdf_y = tsdf_volume.ptr(z*volume_res+(y+1))[x];
		 float tsdf_z = tsdf_volume.ptr((z+1)*volume_res+y)[x];

		 //Weight values
		 float wx = weight_volume.ptr(z*volume_res+y)[x+1];
		 float wy = weight_volume.ptr(z*volume_res+(y+1))[x];
		 float wz = weight_volume.ptr((z+1)*volume_res+y)[x];
		 if (wx <= 0 || wy <= 0 || wz <= 0)
			 continue;
		 //Find zero-crossing by checking neighbor pixels in x,y,z - axis,
		 //surface if negative - positive values in x,y,z directions
		 const bool is_surface_x = ((tsdf > 0) && (tsdf_x < 0)) || ((tsdf < 0) && (tsdf_x > 0));
		 const bool is_surface_y = ((tsdf > 0) && (tsdf_y < 0)) || ((tsdf < 0) && (tsdf_y > 0));
		 const bool is_surface_z = ((tsdf > 0) && (tsdf_z < 0)) || ((tsdf < 0) && (tsdf_z > 0));
		 //indices of surface are found, now compute the world coordinate of indices
		 if (is_surface_x || is_surface_y || is_surface_z) {
			 //Compute normal
             float3 normal;

             normal.x = tsdf_x - tsdf;
             normal.y = tsdf_y - tsdf;
             normal.z = tsdf_z - tsdf;
             float norm_normal =  norm(normal);
             if(norm_normal ==0)
				 continue;
             normal = normalized(normal);

			 //counting number of points
			 int count =0;
			 if(is_surface_x) count++;
			 if(is_surface_y) count++;
			 if(is_surface_z) count++;
			 //if found, increment number of point
			 int index = atomicAdd(point_num,count);
			 //world coordinate of each index
			 float pt_base_x = original_distance_x + (static_cast<float>(x)+0.5) * voxel_size;
			 float pt_base_y = original_distance_y + (static_cast<float>(y)+0.5) * voxel_size;
			 float pt_base_z = original_distance_z + (static_cast<float>(z)+0.5) * voxel_size;
			 /*
			  * update new zero-crossing in x,y,z directions in figure 2, page 3
			  * https://graphics.stanford.edu/papers/volrange/volrange.pdf
			  */
			 if (is_surface_x) {
				 pt_base_x = pt_base_x - (tsdf / (tsdf_x - tsdf)) * voxel_size;
			     vertices.ptr(0)[index] = float3{pt_base_x, pt_base_y, pt_base_z};
                 normals.ptr(0)[index] = float3{normal.x, normal.y, normal.z};

			     color.ptr(0)[index] = color_volume.ptr(z * volume_res + y)[x];

			     index++;
			 }
			 if (is_surface_y) {
				 pt_base_y = pt_base_y - (tsdf / (tsdf_y - tsdf)) * voxel_size;
				 vertices.ptr(0)[index] = float3{pt_base_x, pt_base_y, pt_base_z};
                 normals.ptr(0)[index] = float3{normal.x, normal.y, normal.z};
				 color.ptr(0)[index] = color_volume.ptr(z * volume_res + y)[x];
				 index++;
			 }
			 if (is_surface_z) {
				 pt_base_z = pt_base_z - (tsdf / (tsdf_z - tsdf)) * voxel_size;
				 vertices.ptr(0)[index] = float3{pt_base_x, pt_base_y, pt_base_z};
                 normals.ptr(0)[index] = float3{normal.x, normal.y, normal.z};
				 color.ptr(0)[index] = color_volume.ptr(z * volume_res + y)[x];
				 //printf("%d \n",color.ptr(0)[index].y);
				 index++;
			 }

		 }


	 }
}
/*
 __global__ void saveBinFile(const cv::cuda::PtrStepSz<float> tsdf_volume,
		 	 	 	 	 	 const int volume_res,
		 	 	 	 	 	 const float voxel_size,
		 	 	 	 	 	 const float original_distance_x,
		 	 	 	 	 	 const float original_distance_y,
		 	 	 	 	 	 const float original_distance_z,
		 	 	 	 	 	 std::ofstream outFile)
 {
	 //Get id of each thread in 2 dimensions
	 	 const int x = blockIdx.x * blockDim.x + threadIdx.x;
	 	 const int y = blockIdx.y * blockDim.y + threadIdx.y;
	 	 if(x>volume_res || y>volume_res)
	 	 	return;
		 for(int z =0;z<volume_res;z++)
		 {
			 const float tsdf = tsdf_volume.ptr(z*volume_res+y)[x];
			 outFile(voxel_grid_saveto_path, std::ios::binary | std::ios::out);
		 }
 }
*/
//__global__ void extractMesh()
    
void hostPrintTSDF(const VolumeData& volume,float* tsdf_float)
{
	dim3 threads(WARP_SIZE,WARP_SIZE);
	dim3 blocks((volume.volume_res_ + threads.x -1)/threads.x,
				(volume.volume_res_ + threads.y -1)/threads.y);
	kernelPrintTSDF<<<blocks,threads>>>(volume.tsdf_volume,volume.volume_res_,tsdf_float);
    CudaSafeCall ( cudaGetLastError () );
    CudaSafeCall (cudaDeviceSynchronize ());

}
PointCloud hostExtractPointCloud(const VolumeData& volume,
								 const int buffer_size,
								 const float original_distance_x,
								 const float original_distance_y,
								 const float original_distance_z)
{
	CloudData cloud_data { buffer_size };
	dim3 threads(WARP_SIZE,WARP_SIZE);
	dim3 blocks((volume.volume_res_ + threads.x -1)/threads.x,
				(volume.volume_res_ + threads.y -1)/threads.y);
	kernelExtractPointCloud <<< blocks, threads >>> (volume.tsdf_volume,
				volume.color_volume,
				volume.weight_volume,
				volume.volume_res_,
				volume.voxel_size_,
				cloud_data.vertices,
				cloud_data.normals,
				cloud_data.color,
				cloud_data.point_num,
				original_distance_x,
				original_distance_y,
				original_distance_z
				);
    CudaSafeCall ( cudaGetLastError () );
    CudaSafeCall (cudaDeviceSynchronize ());
		 //Transfer back to CPU
		 cloud_data.download();
		 //Return result in CPU
		 return PointCloud {cloud_data.host_vertices, cloud_data.host_normals,
		 cloud_data.host_color, cloud_data.host_point_num};
}
}



