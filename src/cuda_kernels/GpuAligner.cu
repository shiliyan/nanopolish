#include <iostream>
#include <cuda.h>
#include "GpuAligner.h"
#include <vector>
#include "nanopolish_profile_hmm_r9.h"

#define MAX_STATES 128

__device__ float logsumexpf(float x, float y){
    if(x == -INFINITY && y == -INFINITY){
        return -INFINITY;
    }
    float result = fmax(x, y) + log1pf(expf(-fabsf(y - x)));
    return result;
}

__device__ float lp_match_r9(int rank,
                             float mean,
                             float * poreModelLevelLogStdv,
                             float * poreModelLevelStdv,
                             float * poreModelLevelMean,
                             float scale,
                             float shift,
                             float var,
                             float logVar,
                             bool debug = false){

    float log_inv_sqrt_2pi = log(0.3989422804014327);

    float level = mean;
    float gaussian_mean = scale * poreModelLevelMean[rank] + shift;
    float gaussian_stdv = poreModelLevelStdv[rank] * var;
    float gaussian_log_level_stdv = poreModelLevelLogStdv[rank] + logVar;

    float a = (level - gaussian_mean) / gaussian_stdv;

    float emission = log_inv_sqrt_2pi - gaussian_log_level_stdv + (-0.5f * a * a);

    return emission;

}

__global__ void getScores(float * eventData,
                          float * readEventsPerBase,
                          int * numRowsPerRead,
                          int * eventStarts,
                          int * eventStrides,
                          int * kmer_ranks,
                          int * kmer_ranks_rc,
                          int * eventOffsets, // Offset to use for getting an event IDX for a specific read (read obtained by block IDX)
                          float * poreModelLevelLogStdv,
                          float * poreModelLevelStdv,
                          float * poreModelLevelMean,
                          float * scaleDev,
                          float * shiftDev,
                          float * varDev,
                          float * logVarDev,
                          float * preFlankingDev,
                          float * postFlankingDev,
                          float * returnValues) {

    bool debug = false;
    if(threadIdx.x==0 && blockIdx.x==0){
        debug=true;
    }
    // Initialise the prev probability row, which is the row of the DP table

    int n_kmers = blockDim.x;
    int n_states = n_kmers * PSR9_NUM_STATES + 2 * PSR9_NUM_STATES; // 3 blocks per kmer and then 3 each for start and end state.

    //initialise the return value// Better to do this in a register
    returnValues[blockIdx.x] = -INFINITY;
    __syncthreads();

    __shared__ float prevProbabilities[MAX_STATES];

    // Initialise the previous probabilities - this may not be quite correct as the intialization is different to the C++ version but I don't think it matter
    for (int i = 0; i < n_states - PSR9_NUM_STATES; i++) {
        prevProbabilities[i] = -INFINITY;
    }
    for (int i = n_states - PSR9_NUM_STATES; i < n_states; i++) {
        prevProbabilities[i] = 0.0f; // Is this correct?
    }

    //Step 1: calculate transitions. For now we are going to use external params.
    int readIdx = blockIdx.x;
    float read_events_per_base = readEventsPerBase[readIdx];
    int numRows = numRowsPerRead[readIdx]; // Number of rows in this DP table.
    int e_start = eventStarts[readIdx]; // Event start for read
    int e_stride = eventStrides[readIdx];
    int e_offset = eventOffsets[readIdx]; // Within the event means etc, the offset needed for this block to get a specific event

    bool rc = false;
    if (e_stride == -1){
        rc = true;
    }

    int kmerIdx = threadIdx.x;
    uint32_t rank;

    if (rc == true) {
        rank = kmer_ranks_rc[kmerIdx];
    }else{
        rank = kmer_ranks[kmerIdx];
    }

    float p_stay = 1 - (1 / read_events_per_base);
    float p_skip = 0.0025;
    float p_bad = 0.001;
    float p_bad_self = p_bad;
    float p_skip_self = 0.3;

    float p_mk = p_skip; // probability of not observing an event at all
    float p_mb = p_bad; // probabilty of observing a bad event
    float p_mm_self = p_stay; // probability of observing additional events from this k-mer
    float p_mm_next = 1.0f - p_mm_self - p_mk - p_mb; // normal movement from state to state

    // transitions from event split state in previous block
    float p_bb = p_bad_self;
    float p_bk, p_bm_next, p_bm_self;
    p_bk = p_bm_next = p_bm_self = (1.0f - p_bb) / 3;

    // transitions from kmer skip state in previous block
    float p_kk = p_skip_self;
    float p_km = 1.0f - p_kk;

    // We assign some transition probabilities. I believe this is correct and they don't vary by location in the sequence
    float lp_mk = log(p_mk);
    float lp_mb = log(p_mb);
    float lp_mm_self = log(p_mm_self);
    float lp_mm_next = log(p_mm_next);
    float lp_bb = log(p_bb);
    float lp_bk = log(p_bk);
    float lp_bm_next = log(p_bm_next);
    float lp_bm_self = log(p_bm_self);
    float lp_kk = log(p_kk);
    float lp_km = log(p_km);

    float lp_sm, lp_ms;
    lp_sm = lp_ms = 0.0f;

    // Start filling out the "DP table"
    // Each thread is going to work on an individual P-HMM Block
    // WRONG - need to use threadIdx & think carefully. we have one thread per block/kmer. each block has 3 states tho.
    //int kmerIdx = blockIdx.x;
    int curBlockIdx = kmerIdx + 1; // Accounts for fact that we are not working with start block.
    int prevBlockIdx = curBlockIdx -1;
    int prevBlockOffset = PSR9_NUM_STATES * prevBlockIdx;
    int curBlockOffset = PSR9_NUM_STATES * curBlockIdx;

    // the penalty is controlled by the transition probability
    float BAD_EVENT_PENALTY = 0.0f;

    float scale = scaleDev[readIdx];
    float shift = shiftDev[readIdx];
    float var = varDev[readIdx];
    float logVar = logVarDev[readIdx];

    for(int row=1; row<numRows + 1;row++){
        // Emission probabilities
        int event_idx = e_start + (row - 1) * e_stride;
        float event_mean = eventData[e_offset + row - 1];
        float preFlank = preFlankingDev[e_offset + row - 1];
        float postFlank = postFlankingDev[e_offset + row - 1];

        float lp_emission_m = lp_match_r9(rank,
                                          event_mean,
                                          poreModelLevelLogStdv,
                                          poreModelLevelStdv,
                                          poreModelLevelMean,
                                          scale,
                                          shift,
                                          var,
                                          logVar,
                                          debug);


        float lp_emission_b = BAD_EVENT_PENALTY;

        // Get all the scores for a match
        float HMT_FROM_SAME_M = lp_mm_self + prevProbabilities[curBlockOffset + PSR9_MATCH];
        float HMT_FROM_PREV_M = lp_mm_next + prevProbabilities[prevBlockOffset + PSR9_MATCH];
        float HMT_FROM_SAME_B = lp_bm_self + prevProbabilities[curBlockOffset + PSR9_BAD_EVENT];
        float HMT_FROM_PREV_B = lp_bm_next + prevProbabilities[prevBlockOffset + PSR9_BAD_EVENT];
        float HMT_FROM_PREV_K = lp_km + prevProbabilities[prevBlockOffset + PSR9_KMER_SKIP];

        // m_s is the probability of going from the start state
        // to this kmer. The start state is (currently) only
        // allowed to go to the first kmer. If ALLOW_PRE_CLIP
        // is defined, we allow all events before this one to be skipped,
        // with a penalty;
        float HMT_FROM_SOFT = (kmerIdx == 0 &&
                               (event_idx == e_start ||
                                (HAF_ALLOW_PRE_CLIP)))  ? lp_sm  + preFlank : -INFINITY; // TODO: Add flag for HAF ALLOW_PRE_CLIP

        // calculate the score
        float sum = HMT_FROM_SAME_M;
        sum = logsumexpf(sum, HMT_FROM_SOFT);
        sum = logsumexpf(sum, HMT_FROM_PREV_M);
        sum = logsumexpf(sum, HMT_FROM_SAME_B);
        sum = logsumexpf(sum, HMT_FROM_PREV_B);
        sum = logsumexpf(sum, HMT_FROM_PREV_K);
        sum += lp_emission_m;

        float newMatchScore = sum;

        // Calculate the bad event scores
        // state PSR9_BAD_EVENT
        HMT_FROM_SAME_M = lp_mb + prevProbabilities[curBlockOffset + PSR9_MATCH];
        HMT_FROM_PREV_M = -INFINITY; // not allowed
        HMT_FROM_SAME_B = lp_bb + prevProbabilities[curBlockOffset + PSR9_BAD_EVENT];
        HMT_FROM_PREV_B = -INFINITY;
        HMT_FROM_PREV_K = -INFINITY;
        HMT_FROM_SOFT = -INFINITY;

        sum = HMT_FROM_SAME_M;
        sum = logsumexpf(sum, HMT_FROM_PREV_M);
        sum = logsumexpf(sum, HMT_FROM_SAME_B);
        sum = logsumexpf(sum, HMT_FROM_PREV_B);
        sum = logsumexpf(sum, HMT_FROM_PREV_K);
        sum = logsumexpf(sum, HMT_FROM_SOFT);
        sum += lp_emission_b;

        float newBadEventScore = sum;
        __syncthreads();
        // Write row out. prevProbabilities now becomes "current probabilities" for evaluating skips.
        prevProbabilities[curBlockOffset + PSR9_MATCH] = newMatchScore;
        prevProbabilities[curBlockOffset + PSR9_BAD_EVENT] = newBadEventScore;
        __syncthreads();

        // state PSR9_KMER_SKIP
        HMT_FROM_SAME_M = -INFINITY;
        HMT_FROM_PREV_M = lp_mk + prevProbabilities[prevBlockOffset + PSR9_MATCH];
        HMT_FROM_SAME_B = -INFINITY;
        HMT_FROM_PREV_B = lp_bk + prevProbabilities[prevBlockOffset + PSR9_BAD_EVENT];
        HMT_FROM_SOFT = -INFINITY;

        sum = HMT_FROM_SAME_M;
        sum = logsumexpf(sum, HMT_FROM_PREV_M);
        sum = logsumexpf(sum, HMT_FROM_SAME_B);
        sum = logsumexpf(sum, HMT_FROM_PREV_B);
        sum = logsumexpf(sum, HMT_FROM_PREV_K);
        sum = logsumexpf(sum, HMT_FROM_SOFT);
        sum += 0.0; //No emission. redundant.

        float newSkipScore = sum;

        prevProbabilities[curBlockOffset + PSR9_KMER_SKIP] = newSkipScore;
        __syncthreads();

        //Now need to do the skip-skip transition, which is serial so for now letting one thread execute it.
        if (threadIdx.x == 0){
            for (int blkidx=2; blkidx <= blockDim.x; blkidx++){
                auto skipIdx = blkidx * PSR9_NUM_STATES + PSR9_KMER_SKIP;
                float prevSkipScore = prevProbabilities[skipIdx - PSR9_NUM_STATES];
                float curSkipScore = prevProbabilities[skipIdx];
                HMT_FROM_PREV_K = lp_kk + prevSkipScore;
                newSkipScore = logsumexpf(curSkipScore, HMT_FROM_PREV_K);
                prevProbabilities[skipIdx] = newSkipScore;
                __syncthreads();
            }
        }

        __syncthreads();

        int lastKmerIdx = n_kmers -1;
        int lastRowIdx = numRows -1;
        float end;
        // Now do the post-clip transition
        if(kmerIdx == lastKmerIdx && ( (HAF_ALLOW_POST_CLIP) || row == lastRowIdx)) {
            float lp1 = lp_ms + prevProbabilities[curBlockOffset + PSR9_MATCH] + postFlank;
            float lp2 = lp_ms + prevProbabilities[curBlockOffset + PSR9_BAD_EVENT] + postFlank;
            float lp3 = lp_ms + prevProbabilities[curBlockOffset + PSR9_KMER_SKIP] + postFlank;

            end = returnValues[blockIdx.x];
            end = logsumexpf(end, lp1);
            end = logsumexpf(end, lp2);
            end = logsumexpf(end, lp3);
            returnValues[blockIdx.x] = end;
        }
        // Now do the end state
        __syncthreads();

        }
        __syncthreads();
}


GpuAligner::GpuAligner()
{
    int numModelElements = 4096;
    int max_num_reads = 300;

    poreModelInitialized = false;

    cudaMalloc( (void**)&poreModelLevelMeanDev, numModelElements * sizeof(float));
    cudaMalloc( (void**)&poreModelLevelLogStdvDev, numModelElements * sizeof(float));
    cudaMalloc( (void**)&poreModelLevelStdvDev, numModelElements * sizeof(float));

    cudaMalloc( (void**)&scaleDev, max_num_reads * sizeof(float));
    cudaMalloc( (void**)&shiftDev, max_num_reads * sizeof(float));
    cudaMalloc( (void**)&varDev, max_num_reads * sizeof(float));
    cudaMalloc( (void**)&logVarDev, max_num_reads * sizeof(float));

    cudaMalloc( (void**)&eventsPerBaseDev, max_num_reads * sizeof(float));

    int max_n_rows = 100;
    int maxBuffer = 50000 * sizeof(float);  //TODO: allocate more smartly

    cudaMalloc( (void**)&numRowsDev, max_n_rows * sizeof(int));
    cudaMalloc( (void**)&eventStartsDev, maxBuffer);
    cudaMalloc( (void**)&eventStridesDev, maxBuffer);
    cudaMalloc( (void**)&eventOffsetsDev, maxBuffer);

    cudaMalloc( (void**)&eventMeansDev, maxBuffer);
    cudaMalloc( (void**)&preFlankingDev, maxBuffer);
    cudaMalloc( (void**)&postFlankingDev, maxBuffer);

    //Allocate a host buffer to store the event means, pre and post-flank data
    cudaHostAlloc(&eventMeans, maxBuffer , cudaHostAllocDefault);
    cudaHostAlloc(&preFlankingHost, maxBuffer, cudaHostAllocDefault);
    cudaHostAlloc(&postFlankingHost, maxBuffer, cudaHostAllocDefault);

    int max_num_sequences = 8;
    kmerRanksDevPointers.resize(max_num_sequences);
    kmerRanksRCDevPointers.resize(max_num_sequences);
    returnValuesDevResultsPointers.resize(max_num_sequences);
    returnValuesHostResultsPointers.resize(max_num_sequences);

    for (int i =0; i<max_num_sequences;i++){
        int *kmerRanksDev;
        int *kmerRanksRCDev;
        float * returnValuesDev;
        float* returnedValues;

        cudaMalloc((void **) &returnValuesDev, sizeof(float) * max_num_reads); //one score per read
        cudaHostAlloc(&returnedValues, max_num_reads * sizeof(float) , cudaHostAllocDefault);

        cudaMalloc((void **) &kmerRanksDev, max_n_rows * sizeof(int));
        cudaMalloc((void **) &kmerRanksRCDev, max_n_rows * sizeof(int));

        kmerRanksDevPointers[i] = kmerRanksDev;
        kmerRanksRCDevPointers[i] = kmerRanksRCDev;
        returnValuesDevResultsPointers[i] = returnValuesDev;
        returnValuesHostResultsPointers[i] = returnedValues;

        //create a stream per sequence
        cudaStreamCreate(&streams[i]);
    }
}

//Destructor
GpuAligner::~GpuAligner() {
    cudaFree(poreModelLevelMeanDev);
    cudaFree(scaleDev);
    cudaFree(shiftDev);
    cudaFree(varDev);
    cudaFree(logVarDev);
    cudaFree(eventMeansDev);
    cudaFree(eventsPerBaseDev);
    cudaFree(numRowsDev);
    cudaFree(eventStartsDev);
    cudaFree(eventStridesDev);
    cudaFree(eventOffsetsDev);
    cudaFree(poreModelLevelLogStdvDev);
    cudaFree(poreModelLevelStdvDev);
    cudaFree(preFlankingDev);
    cudaFree(postFlankingDev);

    cudaFreeHost(eventMeans);
    cudaFreeHost(preFlankingHost);
    cudaFreeHost(postFlankingHost);

    int max_num_sequences = 8; // should be a private variable
    // Free device and host memory
    for (int i =0; i<max_num_sequences; i++) {
        cudaStreamDestroy(streams[i]);
        cudaFree(kmerRanksRCDevPointers[i]);
        cudaFree(kmerRanksDevPointers[i]);
        cudaFree(returnValuesDevResultsPointers[i]);
        cudaFreeHost(returnValuesHostResultsPointers[i]);
    }

}

std::vector<std::vector<double>> GpuAligner::scoreKernel(std::vector<HMMInputSequence> sequences,
                                                std::vector<HMMInputData> event_sequences,
                                                uint32_t alignment_flags){
    // pre-running asserts
    assert(!sequences.empty());
    assert(!event_sequences.empty());
    assert(std::string(sequences[0].get_alphabet()->get_name()) == "nucleotide");
    for (auto e: event_sequences) {
        assert(std::string(e.pore_model->pmalphabet->get_name()) == "nucleotide");
        assert(e.read->pore_type == PT_R9);
        assert( (e.rc && e.event_stride == -1) || (!e.rc && e.event_stride == 1));
    }

    int num_reads = event_sequences.size();

    const uint32_t k = event_sequences[0].pore_model->k; //k is the length of a kmer

    std::vector<uint32_t> n_rows; //number of rows in the DP table (n_events) for each read
    std::vector<uint32_t> e_starts; //event starts in the read for each read
    std::vector<int> event_strides; //event strides for each read
    std::vector<std::vector<float>> pre_flanks;
    std::vector<std::vector<float>> post_flanks;
    std::vector<float> eventsPerBase;

    //Populate per-read vectors
    int numEventsTotal = 0;
    for(auto e: event_sequences){
        uint32_t e_start = e.event_start_idx;
        e_starts.push_back(e_start);

        uint32_t e_stride = e.event_stride;
        event_strides.push_back(e_stride);

        uint32_t e_end = e.event_stop_idx;
        uint32_t n_events = 0;
        if(e_end > e_start)
            n_events = e_end - e_start + 1;
        else
            n_events = e_start - e_end + 1;

        n_rows.push_back(n_events);
        numEventsTotal += n_events;

        std::vector<float> pre_flank = make_pre_flanking(e, e_start, n_events);
        std::vector<float> post_flank = make_post_flanking(e, e_start, n_events);

        pre_flanks.push_back(pre_flank);
        post_flanks.push_back(post_flank);

        float readEventsPerBase = e.read->events_per_base[e.strand];
        eventsPerBase.push_back(readEventsPerBase);
    }

    //Populate buffers for flanks and scaled means data
    std::vector<int> eventOffsets;
    size_t offset = 0;
    for(int j=0; j<num_reads; j++){
        auto e = event_sequences[j];
        eventOffsets.push_back(offset);
        size_t num_events = n_rows[j];
        for (int i=0;i<num_events;i++) {
            auto event_idx =  e_starts[j] + i * event_strides[j];
            auto scaled = e.read->get_drift_scaled_level(event_idx, e.strand); // send the data in drift scaled
            eventMeans[offset + i] = scaled;
            preFlankingHost[offset + i] = pre_flanks[j][i]; //also copy over the pre-flanking data, since it has a 1-1 correspondence with events
            postFlankingHost[offset + i] = post_flanks[j][i]; //also copy over the pre-flanking data, since it has a 1-1 correspondence with events
        }
        offset += num_events;
    }

    // Populate pore model buffers
    // Assume that every event sequence has the same pore model
    int num_states = event_sequences[0].pore_model->states.size();
    std::vector<float> pore_model_level_log_stdv(num_states);
    std::vector<float> pore_model_level_mean(num_states);
    std::vector<float> pore_model_level_stdv(num_states);
    for(int st=0; st<num_states; st++){
        auto params = event_sequences[0].pore_model->states[st];
        pore_model_level_log_stdv[st] = params.level_log_stdv; //TODO: I am seeing level log stdv and level stdv return the same value. need to investigate this.
        pore_model_level_stdv[st] = params.level_stdv;
        pore_model_level_mean[st] = params.level_mean;
    }

    //Populating read-statistics buffers
    std::vector<float> scale(num_reads);
    std::vector<float> shift(num_reads);
    std::vector<float> var(num_reads);
    std::vector<float> log_var(num_reads);
    for (int i=0;i<num_reads;i++){
        auto read = event_sequences[i];
        scale[i] = event_sequences[i].read->scalings[read.strand].scale;
        shift[i] = event_sequences[i].read->scalings[read.strand].shift;
        var[i] = event_sequences[i].read->scalings[read.strand].var;
        log_var[i] = event_sequences[i].read->scalings[read.strand].log_var;
    }

    // Copy to the device all buffers shared across kmer sequences.
    cudaMemcpyAsync( scaleDev, scale.data(), scale.size() * sizeof(float), cudaMemcpyHostToDevice );
    cudaMemcpyAsync( shiftDev, shift.data(), shift.size() * sizeof(float), cudaMemcpyHostToDevice );
    cudaMemcpyAsync( varDev, var.data(), var.size() * sizeof(float), cudaMemcpyHostToDevice );
    cudaMemcpyAsync( logVarDev, log_var.data(), log_var.size() * sizeof(float), cudaMemcpyHostToDevice );
    cudaMemcpyAsync( eventsPerBaseDev, eventsPerBase.data(), eventsPerBase.size() * sizeof(float), cudaMemcpyHostToDevice );
    cudaMemcpyAsync( eventMeansDev, eventMeans, numEventsTotal * sizeof(float), cudaMemcpyHostToDevice );
    cudaMemcpyAsync( preFlankingDev, preFlankingHost, numEventsTotal * sizeof(float), cudaMemcpyHostToDevice );
    cudaMemcpyAsync( postFlankingDev, postFlankingHost, numEventsTotal * sizeof(float), cudaMemcpyHostToDevice );
    cudaMemcpyAsync( numRowsDev, n_rows.data(), n_rows.size() * sizeof(int), cudaMemcpyHostToDevice );
    cudaMemcpyAsync( eventStartsDev, e_starts.data(), e_starts.size() * sizeof(int), cudaMemcpyHostToDevice );
    cudaMemcpyAsync( eventStridesDev, event_strides.data(), event_strides.size() * sizeof(int), cudaMemcpyHostToDevice );
    cudaMemcpyAsync( eventOffsetsDev, eventOffsets.data(), eventOffsets.size() * sizeof(int), cudaMemcpyHostToDevice );

    if (poreModelInitialized == false) {
        cudaMemcpyAsync(poreModelLevelLogStdvDev, pore_model_level_log_stdv.data(),
                        pore_model_level_log_stdv.size() * sizeof(float), cudaMemcpyHostToDevice);
        cudaMemcpyAsync(poreModelLevelMeanDev, pore_model_level_mean.data(),
                        pore_model_level_mean.size() * sizeof(float), cudaMemcpyHostToDevice);
        cudaMemcpyAsync(poreModelLevelStdvDev, pore_model_level_stdv.data(),
                        pore_model_level_stdv.size() * sizeof(float), cudaMemcpyHostToDevice);
        poreModelInitialized = true;
    }

    uint8_t  MAX_NUM_KMERS = 30;
    for (size_t i =0; i < sequences.size();i++){

        int * kmerRanksDev = kmerRanksDevPointers[i];
        int * kmerRanksRCDev = kmerRanksRCDevPointers[i];
        float * returnValuesDev = returnValuesDevResultsPointers[i];

        auto sequence = sequences[i];
        uint32_t n_kmers = sequence.length() - k + 1; //number of kmers in the sequence
        uint32_t n_states = PSR9_NUM_STATES * (n_kmers + 2); // + 2 for explicit terminal states

        std::vector<uint32_t> kmer_ranks(n_kmers);
        std::vector<uint32_t> kmer_ranks_rc(n_kmers);

        for(size_t ki = 0; ki < n_kmers; ++ki) {
            kmer_ranks[ki] = sequence.get_kmer_rank(ki, k, false);
            kmer_ranks_rc[ki] = sequence.get_kmer_rank(ki, k, true);
        }

        assert(kmer_ranks.size() < MAX_NUM_KMERS);
        cudaMemcpyAsync(kmerRanksDev, kmer_ranks.data(), kmer_ranks.size() * sizeof(int),
                        cudaMemcpyHostToDevice, streams[i]);
        cudaMemcpyAsync(kmerRanksRCDev, kmer_ranks_rc.data(), kmer_ranks_rc.size() * sizeof(int),
                        cudaMemcpyHostToDevice, streams[i]);

        int num_blocks = n_states / PSR9_NUM_STATES;

        dim3 dimBlock(num_blocks - 2); // One thread per state, not including Start and Terminal state.
        dim3 dimGrid(num_reads); // let's look at only the first read

        getScores <<< dimGrid, dimBlock, 0, streams[i]>>> (eventMeansDev,
                eventsPerBaseDev,
                numRowsDev,
                eventStartsDev,
                eventStridesDev,
                kmerRanksDev,
                kmerRanksRCDev,
                eventOffsetsDev,
                poreModelLevelLogStdvDev,
                poreModelLevelStdvDev,
                poreModelLevelMeanDev,
                scaleDev,
                shiftDev,
                varDev,
                logVarDev,
                preFlankingDev,
                postFlankingDev,
                returnValuesDev);

        cudaMemcpyAsync(returnValuesHostResultsPointers[i], returnValuesDevResultsPointers[i], num_reads *sizeof(float), cudaMemcpyDeviceToHost, streams[i]);
    }

    std::vector<std::vector<double>> results(sequences.size());
    for (size_t i =0; i<sequences.size();i++) {
        for(int readIdx=0; readIdx<num_reads;readIdx++) {
            results[i].resize(num_reads);
        }
    }

    cudaDeviceSynchronize();

    for (size_t i =0; i<sequences.size();i++) {
        for(int readIdx=0; readIdx<num_reads;readIdx++) {
            results[i][readIdx] = (double) returnValuesHostResultsPointers[i][readIdx];
        }
    }

    return results;
}

std::vector<Variant> GpuAligner::variantScoresThresholded(std::vector<Variant> input_variants,
                                                        Haplotype base_haplotype,
                                                        std::vector<HMMInputData> event_sequences,
                                                        uint32_t alignment_flags,
                                                        int screen_score_threshold,
                                                        std::vector<std::string> methylation_types) {
    int numVariants = input_variants.size();

    std::vector<Variant> out_variants = input_variants;
    std::vector<Haplotype> variant_haplotypes(numVariants, base_haplotype);

    //loop over the vector, applying the variants to the haplotypes
    for (int i = 0; i<input_variants.size();i++){
        variant_haplotypes[i].apply_variant(input_variants[i]);
    }

    // Make methylated versions of each input sequence. Once for the base haplotype and once each for each variant

    std::vector<HMMInputSequence> sequences;

    HMMInputSequence base_sequence = generate_methylated_alternatives(base_haplotype.get_sequence(),
                                                                                    methylation_types)[0]; //TODO: fix for non-zero

    sequences.push_back(base_sequence);

    for (auto v: variant_haplotypes){
        auto variant_sequence = generate_methylated_alternatives(v.get_sequence(), methylation_types)[0];  //TODO: fix for non-zero
        sequences.push_back(variant_sequence);
    }

    std::vector<Variant> v = input_variants;

    if (!event_sequences.empty()) {
        std::vector<std::vector<double>> scores = scoreKernel(sequences, event_sequences, alignment_flags);
        uint32_t numScores = scores[0].size();
        for (int variantIndex = 0; variantIndex < numVariants; variantIndex++) { // index 0 is the base scores
            double totalScore = 0.0;
            for (int k = 0; k < numScores; k++) {
                if (fabs(totalScore) < screen_score_threshold) {
                    double baseScore = scores[0][k];
                    totalScore += (scores[variantIndex + 1][k] - baseScore);
                }
            }
            v[variantIndex].quality = totalScore;
            v[variantIndex].info = "";
        }
    }

    return v;
}