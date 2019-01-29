// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * hits_problem.cuh
 *
 * @brief GPU Storage management Structure for hits Problem Data
 */

#pragma once

#include <gunrock/app/problem_base.cuh>

namespace gunrock {
namespace app {
namespace hits {


/**
 * @brief Speciflying parameters for hits Problem
 * @param  parameters  The util::Parameter<...> structure holding all parameter info
 * \return cudaError_t error message(s), if any
 */
cudaError_t UseParameters_problem(
    util::Parameters &parameters)
{
    cudaError_t retval = cudaSuccess;

    GUARD_CU(gunrock::app::UseParameters_problem(parameters));

    // <TODO> Add problem specific command-line parameter usages here, e.g.:
    // GUARD_CU(parameters.Use<bool>(
    //    "mark-pred",
    //    util::OPTIONAL_ARGUMENT | util::MULTI_VALUE | util::OPTIONAL_PARAMETER,
    //    false,
    //    "Whether to mark predecessor info.",
    //    __FILE__, __LINE__));
    // </TODO>

    return retval;
}

/**
 * @brief Template Problem structure.
 * @tparam _GraphT  Type of the graph
 * @tparam _FLAG    Problem flags
 */
template <
    typename _GraphT,
    ProblemFlag _FLAG = Problem_None>
struct Problem : ProblemBase<_GraphT, _FLAG>
{
    typedef _GraphT GraphT;
    static const ProblemFlag FLAG = _FLAG;
    typedef typename GraphT::VertexT VertexT;
    typedef typename GraphT::ValueT  ValueT;
    typedef typename GraphT::SizeT   SizeT;
    typedef typename GraphT::CsrT    CsrT;
    typedef typename GraphT::GpT     GpT;

    typedef ProblemBase   <GraphT, FLAG> BaseProblem;
    typedef DataSliceBase <GraphT, FLAG> BaseDataSlice;

    // ----------------------------------------------------------------
    // Dataslice structure

    /**
     * @brief Data structure containing problem specific data on indivual GPU.
     */
    struct DataSlice : BaseDataSlice
    {
        util::Array1D<SizeT, ValueT> degrees;
        util::Array1D<SizeT, int> visited;

        // HITS problem-specific storage arrays
        util::Array1D<SizeT, ValueT> hrank_curr;    // Holds hub rank value
        util::Array1D<SizeT, ValueT> arank_curr;    // Holds authority rank value
        util::Array1D<SizeT, ValueT> hrank_next;    
        util::Array1D<SizeT, ValueT> arank_next;    
        util::Array1D<SizeT, ValueT> in_degrees;    // Number of nodes that link to given node
        util::Array1D<SizeT, ValueT> out_degrees;   // Number of nodes given node links to

        SizeT maxIter;                              // Maximum number of HITS iterations

        /*
         * @brief Default constructor
         */
        DataSlice() : BaseDataSlice()
        {
            // Name of the problem specific arrays:
            degrees.SetName("degrees");
            visited.SetName("visited");

            hrank_curr.SetName("hrank_curr");
            arank_curr.SetName("arank_curr");
            hrank_next.SetName("hrank_next");
            arank_next.SetName("arank_next");
            in_degrees.SetName("in_degrees");
            out_degrees.SetName("out_degrees");
        }

        /*
         * @brief Default destructor
         */
        virtual ~DataSlice() { Release(); }

        /*
         * @brief Releasing allocated memory space
         * @param[in] target      The location to release memory from
         * \return    cudaError_t Error message(s), if any
         */
        cudaError_t Release(util::Location target = util::LOCATION_ALL)
        {
            cudaError_t retval = cudaSuccess;
            if (target & util::DEVICE)
                GUARD_CU(util::SetDevice(this->gpu_idx));

            GUARD_CU(degrees.Release(target));
            GUARD_CU(visited.Release(target));

            // Release allocated data
            GUARD_CU(hrank_curr.Release(target));
            GUARD_CU(arank_curr.Release(target));
            GUARD_CU(hrank_next.Release(target));
            GUARD_CU(arank_next.Release(target));
            GUARD_CU(in_degrees.Release(target));
            GUARD_CU(out_degrees.Release(target));

            GUARD_CU(BaseDataSlice ::Release(target));
            return retval;
        }

        /**
         * @brief initializing hits-specific data on each gpu
         * @param     sub_graph   Sub graph on the GPU.
         * @param[in] gpu_idx     GPU device index
         * @param[in] target      Targeting device location
         * @param[in] flag        Problem flag containling options
         * \return    cudaError_t Error message(s), if any
         */
        cudaError_t Init(
            GraphT        &sub_graph,
            int            num_gpus,
            int            gpu_idx,
            util::Location target,
            ProblemFlag    flag)
        {
            cudaError_t retval  = cudaSuccess;

            GUARD_CU(BaseDataSlice::Init(sub_graph, num_gpus, gpu_idx, target, flag));

            // Allocate problem specific data here
            GUARD_CU(degrees.Allocate(sub_graph.nodes, target));
            GUARD_CU(visited.Allocate(sub_graph.nodes, target));

            GUARD_CU(hrank_curr.Allocate(sub_graph.nodes, target));
            GUARD_CU(arank_curr.Allocate(sub_graph.nodes, target));
            GUARD_CU(hrank_next.Allocate(sub_graph.nodes, target));
            GUARD_CU(arank_next.Allocate(sub_graph.nodes, target));
            GUARD_CU(in_degrees.Allocate(sub_graph.nodes, target));
            GUARD_CU(out_degrees.Allocate(sub_graph.nodes, target));

            if (target & util::DEVICE) {
                // <TODO> move sub-graph used by the problem onto GPU,
                GUARD_CU(sub_graph.CsrT::Move(util::HOST, target, this -> stream));
            }
            return retval;
        }

        /**
         * @brief Reset problem function. Must be called prior to each run.
         * @param[in] target      Targeting device location
         * \return    cudaError_t Error message(s), if any
         */
        cudaError_t Reset(util::Location target = util::DEVICE)
        {
            cudaError_t retval = cudaSuccess;
            SizeT nodes = this -> sub_graph -> nodes;

            // Ensure data are allocated
            GUARD_CU(degrees.EnsureSize_(nodes, target));
            GUARD_CU(visited.EnsureSize_(nodes, target));

            GUARD_CU(hrank_curr.EnsureSize_(nodes, target));
            GUARD_CU(arank_curr.EnsureSize_(nodes, target));
            GUARD_CU(hrank_next.EnsureSize_(nodes, target));
            GUARD_CU(arank_next.EnsureSize_(nodes, target));
            GUARD_CU(in_degrees.EnsureSize_(nodes, target));
            GUARD_CU(out_degrees.EnsureSize_(nodes, target));

            // Reset data
            GUARD_CU(degrees.ForEach([]__host__ __device__ (ValueT &x){
               x = (ValueT)0;
            }, nodes, target, this -> stream));

            GUARD_CU(visited.ForEach([]__host__ __device__ (int &x){
               x = (int)0;
            }, nodes, target, this -> stream));

            // Initialize current hrank and arank to 1.
            // Initialize next ranks to 0 (will be updated).
            GUARD_CU(hrank_curr.ForEach([]__host__ __device__ (ValueT &x){
               x = (ValueT)1.0;
            }, nodes, target, this -> stream));

            GUARD_CU(arank_curr.ForEach([]__host__ __device__ (ValueT &x){
               x = (ValueT)1.0;
            }, nodes, target, this -> stream));

            GUARD_CU(hrank_next.ForEach([]__host__ __device__ (ValueT &x){
               x = (ValueT)0.0;
            }, nodes, target, this -> stream));

            GUARD_CU(arank_next.ForEach([]__host__ __device__ (ValueT &x){
               x = (ValueT)0.0;
            }, nodes, target, this -> stream));

            // Initialize number of degrees to zero. May not be needed
            GUARD_CU(in_degrees.ForEach([]__host__ __device__ (ValueT &x){
               x = (ValueT)0;
            }, nodes, target, this -> stream));

            GUARD_CU(out_degrees.ForEach([]__host__ __device__ (ValueT &x){
               x = (ValueT)0;
            }, nodes, target, this -> stream));

            return retval;
        }
    }; // DataSlice

    // Set of data slices (one for each GPU)
    util::Array1D<SizeT, DataSlice> *data_slices;

    // ----------------------------------------------------------------
    // Problem Methods

    /**
     * @brief hits default constructor
     */
    Problem(
        util::Parameters &_parameters,
        ProblemFlag _flag = Problem_None) :
        BaseProblem(_parameters, _flag),
        data_slices(NULL) {}

    /**
     * @brief hits default destructor
     */
    virtual ~Problem() { Release(); }

    /*
     * @brief Releasing allocated memory space
     * @param[in] target      The location to release memory from
     * \return    cudaError_t Error message(s), if any
     */
    cudaError_t Release(util::Location target = util::LOCATION_ALL)
    {
        cudaError_t retval = cudaSuccess;
        if (data_slices == NULL) return retval;
        for (int i = 0; i < this->num_gpus; i++)
            GUARD_CU(data_slices[i].Release(target));

        if ((target & util::HOST) != 0 &&
            data_slices[0].GetPointer(util::DEVICE) == NULL)
        {
            delete[] data_slices; data_slices=NULL;
        }
        GUARD_CU(BaseProblem::Release(target));
        return retval;
    }
    
    /**
     * @brief Copy result distancess computed on GPUs back to host-side arrays.
...
     * \return     cudaError_t Error message(s), if any
     */
    cudaError_t Extract(
        // <TODO> problem specific data to extract
        ValueT *h_degrees,
        // </TODO>
        util::Location target = util::DEVICE)
    {
        cudaError_t retval = cudaSuccess;
        SizeT nodes = this -> org_graph -> nodes;

        if (this-> num_gpus == 1) {
            auto &data_slice = data_slices[0][0];

            // Set device
            if (target == util::DEVICE) {
                GUARD_CU(util::SetDevice(this->gpu_idx[0]));

                // <TODO> extract the results from single GPU, e.g.:
                GUARD_CU(data_slice.degrees.SetPointer(h_degrees, nodes, util::HOST));
                GUARD_CU(data_slice.degrees.Move(util::DEVICE, util::HOST));
                // </TODO>
            } else if (target == util::HOST) {
                // <TODO> extract the results from single CPU, e.g.:
                GUARD_CU(data_slice.degrees.ForEach(h_degrees,
                   []__host__ __device__ (const ValueT &device_val, ValueT &host_val){
                       host_val = device_val;
                   }, nodes, util::HOST));
                // </TODO>
            }
        } else { // num_gpus != 1
            
            // ============ INCOMPLETE TEMPLATE - MULTIGPU ============
            
            // // TODO: extract the results from multiple GPUs, e.g.:
            // // util::Array1D<SizeT, ValueT *> th_distances;
            // // th_distances.SetName("bfs::Problem::Extract::th_distances");
            // // GUARD_CU(th_distances.Allocate(this->num_gpus, util::HOST));

            // for (int gpu = 0; gpu < this->num_gpus; gpu++)
            // {
            //     auto &data_slice = data_slices[gpu][0];
            //     if (target == util::DEVICE)
            //     {
            //         GUARD_CU(util::SetDevice(this->gpu_idx[gpu]));
            //         // GUARD_CU(data_slice.distances.Move(util::DEVICE, util::HOST));
            //     }
            //     // th_distances[gpu] = data_slice.distances.GetPointer(util::HOST);
            // } //end for(gpu)

            // for (VertexT v = 0; v < nodes; v++)
            // {
            //     int gpu = this -> org_graph -> GpT::partition_table[v];
            //     VertexT v_ = v;
            //     if ((GraphT::FLAG & gunrock::partitioner::Keep_Node_Num) != 0)
            //         v_ = this -> org_graph -> GpT::convertion_table[v];

            //     // h_distances[v] = th_distances[gpu][v_];
            // }

            // // GUARD_CU(th_distances.Release());
        }

        return retval;
    }

    /**
     * @brief initialization function.
     * @param     graph       The graph that SSSP processes on
     * @param[in] Location    Memory location to work on
     * \return    cudaError_t Error message(s), if any
     */
    cudaError_t Init(
            GraphT           &graph,
            util::Location    target = util::DEVICE)
    {
        cudaError_t retval = cudaSuccess;
        GUARD_CU(BaseProblem::Init(graph, target));
        data_slices = new util::Array1D<SizeT, DataSlice>[this->num_gpus];

        // <TODO> get problem specific flags from parameters, e.g.:
        // if (this -> parameters.template Get<bool>("mark-pred"))
        //    this -> flag = this -> flag | Mark_Predecessors;
        // </TODO>

        for (int gpu = 0; gpu < this->num_gpus; gpu++) {
            data_slices[gpu].SetName("data_slices[" + std::to_string(gpu) + "]");
            if (target & util::DEVICE)
                GUARD_CU(util::SetDevice(this->gpu_idx[gpu]));

            GUARD_CU(data_slices[gpu].Allocate(1, target | util::HOST));

            auto &data_slice = data_slices[gpu][0];
            GUARD_CU(data_slice.Init(
                this -> sub_graphs[gpu],
                this -> num_gpus,
                this -> gpu_idx[gpu],
                target,
                this -> flag
            ));
        }

        return retval;
    }

    /**
     * @brief Reset problem function. Must be called prior to each run.
     * @param[in] src      Source vertex to start.
     * @param[in] location Memory location to work on
     * \return cudaError_t Error message(s), if any
     */
    cudaError_t Reset(
        // <TODO> problem specific data if necessary, eg
        // VertexT src,
        // </TODO>
        util::Location target = util::DEVICE)
    {
        cudaError_t retval = cudaSuccess;

        // Reset data slices
        for (int gpu = 0; gpu < this->num_gpus; ++gpu) {
            if (target & util::DEVICE)
                GUARD_CU(util::SetDevice(this->gpu_idx[gpu]));
            GUARD_CU(data_slices[gpu] -> Reset(target));
            GUARD_CU(data_slices[gpu].Move(util::HOST, target));
        }

        // <TODO> Additional problem specific initialization
        // </TODO>

        GUARD_CU2(cudaDeviceSynchronize(), "cudaDeviceSynchronize failed");
        return retval;
    }
};

} //namespace Template
} //namespace app
} //namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
