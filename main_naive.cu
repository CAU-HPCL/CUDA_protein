﻿/* include C/C++ header */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>

/* include CUDA header */
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <curand_kernel.h>

#define WARP_SIZE 32

#define NOT_FOUND -1
#define CODON_SIZE 3
#define RANDOM 0
#define UPPER 1

#define OBJECTIVE_NUM 3
#define _mCAI 0
#define _mHD 1
#define _MLRCS 2

#define P 0
#define Q 1
#define L 2

#define FIRST_SOL 1
#define SECOND_SOL 2


/* -------------------- 20 kinds of amino acids & weights are sorted ascending order -------------------- */
char Amino_abbreviation[20] = { 'A','C','D','E','F','G','H','I','K','L','M','N','P','Q','R','S','T','V','W','Y' };
char Codons[61 * CODON_SIZE + 1] = "GCGGCAGCCGCU\
UGCUGU\
GACGAU\
GAGGAA\
UUUUUC\
GGGGGAGGCGGU\
CACCAU\
AUAAUCAUU\
AAAAAG\
CUCCUGCUUCUAUUAUUG\
AUG\
AAUAAC\
CCGCCCCCUCCA\
CAGCAA\
CGGCGACGCAGGCGUAGA\
UCGAGCAGUUCAUCCUCU\
ACGACAACCACU\
GUAGUGGUCGUU\
UGG\
UAUUAC";
char Codons_num[20] = { 4,2,2,2,2,4,2,3,2,6,1,2,4,2,6,6,4,4,1,2 };
float Codons_weight[61] = { 1854 / 13563.0f, 5296 / 13563.0f, 7223 / 135063.0f, 1.0f,\
1234 / 3052.0f, 1.0f,\
8960 / 12731.0f, 1.0f,\
6172 / 19532.0f,1.0f,\
7773 / 8251.0f, 1.0f,\
1852 / 15694.0f, 2781 / 15694.0f, 3600 / 15694.0f, 1.0f,\
3288 / 4320.0f, 1.0f,\
3172 / 12071.0f, 8251 / 12071.0f,1.0f,\
12845 / 15169.0f, 1.0f,\
1242 / 13329.0f, 2852 / 13329.0f, 3207 / 13329.0f, 4134 / 13329.0f, 8549 / 13329.0f, 1.0f,\
1.0f,\
8613 / 9875.0f,1.0f,\
1064 / 8965.0f, 1656 / 8965.0f, 4575 / 8965.0f, 1.0f,\
3312 / 10987.0f, 1.0f,\
342 / 9784.0f, 489 / 9784.0f, 658 / 9784.0f, 2175 / 9784.0f,3307 / 9784.0f, 1.0f,\
2112 / 10025.0f, 2623 / 10025.0f, 3873 / 10025.0f, 4583 / 10025.0f, 6403 / 10025.0f, 1.0f,\
1938 / 9812.0f, 5037 / 9812.0f,6660 / 9812.0f, 1.0f,\
3249 / 11442.0f, 3700 / 11442.0f, 6911 / 11442.0f, 1.0f,\
1.0f,\
5768 / 7114.0f, 1.0f };
/* ------------------------------ end of definition ------------------------------ */


/* find index of Amino_abbreviation array matching with input amino abbreviation using binary search */
__host__ int FindAminoIndex(char amino_abbreviation)
{
	int low = 0;
	int high = 20 - 1;
	int mid;

	while (low <= high) {
		mid = (low + high) / 2;

		if (Amino_abbreviation[mid] == amino_abbreviation)
			return mid;
		else if (Amino_abbreviation[mid] > amino_abbreviation)
			high = mid - 1;
		else
			low = mid + 1;
	}

	return NOT_FOUND;
}


__device__ char FindNum_C(const char* origin, const char* target, const char num_codons)
{
	char i;

	for (i = 0; i < num_codons; i++)
	{
		if (target[0] == origin[i * CODON_SIZE] && target[1] == origin[i * CODON_SIZE + 1] && target[2] == origin[i * CODON_SIZE + 2]) {
			return i;
		}
	}
}

/* mutate codon upper adaptation or randmom adaptation */
__device__ void mutation(curandStateXORWOW *state, const char* codon_info, char* target, char total_num, char origin_pos, const float mprob, const int type)
{
	float cd_prob;
	char new_idx;

	/* 1.0 is included and 0.0 is excluded */
	cd_prob = curand_uniform(state);

	switch (type)
	{
	case RANDOM:
		new_idx = (char)(curand_uniform(state) * total_num);
		if (cd_prob <= mprob && total_num > 1) {
			while (origin_pos == new_idx || new_idx == total_num) {
				new_idx = (char)(curand_uniform(state) * total_num);
			}
			target[0] = codon_info[new_idx * CODON_SIZE];
			target[1] = codon_info[new_idx * CODON_SIZE + 1];
			target[2] = codon_info[new_idx * CODON_SIZE + 2];
		}
		break;

	case UPPER:
		new_idx = (char)(curand_uniform(state) * (total_num - 1 - origin_pos));
		if (cd_prob <= mprob && (origin_pos != (total_num - 1))) {
			while (new_idx == (total_num - 1 - origin_pos)) {
				new_idx = (char)(curand_uniform(state) * (total_num - 1 - origin_pos));
			}
			target[0] = codon_info[(origin_pos + 1 + new_idx) * CODON_SIZE];
			target[1] = codon_info[(origin_pos + 1 + new_idx) * CODON_SIZE + 1];
			target[2] = codon_info[(origin_pos + 1 + new_idx) * CODON_SIZE + 2];
		}
		break;
	}

	return;
}


/* curand generator state setting */
__global__ void setup_kernel(curandStateXORWOW* state, int seed)
{
	int id = blockDim.x * blockIdx.x + threadIdx.x;

	/* Each thread gets same seed, a different sequence number, no offset */
	curand_init(seed, id, 0, &state[id]);

	return;
}

__global__ void mainKernel(curandStateXORWOW* state, const char* d_codons, const char* d_codons_num, const float* d_codons_weight, const char* d_amino_seq_idx, 
	const char * d_amino_startpos, char* d_pop, float * d_objval, const int len_amino_seq, const int cds_num, const int cycle, const float mprob)
{
	int idx, seq_idx;
	char pos;

	int i, j, k, l;
	int num_partition;
	int id;
	int len_cds, len_sol;
	float tmp_objval;
	curandStateXORWOW localState;

	char* ptr_origin_sol, *ptr_target_sol;
	float* ptr_origin_objval, *ptr_target_objval;
	char* ptr_origin_objidx, *ptr_target_objidx;
	int* ptr_origin_lrcsval, * ptr_target_lrcsval;
	char sol_num;									

	id = threadIdx.x + blockIdx.x * blockDim.x;
	localState = state[id];
	len_cds = len_amino_seq * CODON_SIZE;
	len_sol = len_cds * cds_num;


	/* -------------------- shared memory allocation -------------------- */
	extern __shared__ int smem[];
	/* read only */
	__shared__ char* s_amino_seq_idx;				
	__shared__ char* s_amino_startpos;				
	__shared__ char* s_codons;						
	__shared__ char* s_codons_num;					
	__shared__ float* s_codons_weight;				
	/* read & write */
	__shared__ char* s_sol1;							
	__shared__ char* s_sol2;							
	__shared__ char* s_sol1_objidx;
	__shared__ char* s_sol2_objidx;
	__shared__ char* mutation_type;
	__shared__ float* s_obj_compute;					// for computing mCAI & mHD value
	__shared__ float* s_sol1_objval;
	__shared__ float* s_sol2_objval;
	__shared__ int* s_lrcs_compute;
	__shared__ int* s_sol1_lrcsval;
	__shared__ int* s_sol2_lrcsval;

	s_lrcs_compute = smem;
	s_sol1_lrcsval = (int*)&s_lrcs_compute[(len_cds + 1) * 2];
	s_sol2_lrcsval = (int*)&s_sol1_lrcsval[3];
	s_codons_weight = (float*)&s_sol2_lrcsval[3];
	s_obj_compute = (float*)&s_codons_weight[61];
	s_sol1_objval = (float*)&s_obj_compute[blockDim.x];
	s_sol2_objval = (float*)&s_sol1_objval[OBJECTIVE_NUM];
	s_amino_seq_idx = (char*)&s_sol2_objval[OBJECTIVE_NUM];
	s_amino_startpos = (char*)&s_amino_seq_idx[len_amino_seq];
	s_codons = (char*)&s_amino_startpos[20];
	s_codons_num = (char*)&s_codons[183];
	s_sol1 = (char*)&s_codons_num[20];
	s_sol2 = (char*)&s_sol1[len_sol];
	s_sol1_objidx = (char*)&s_sol2[len_sol];
	s_sol2_objidx = (char*)&s_sol1_objidx[OBJECTIVE_NUM * 2];
	mutation_type = (char*)&s_sol2_objidx[OBJECTIVE_NUM * 2];
	/* -------------------- end of shared memory allocation -------------------- */



	/* read only shared memory variable value setting */
	num_partition = (len_amino_seq % blockDim.x == 0) ? len_amino_seq / blockDim.x : len_amino_seq / blockDim.x + 1;
	for (i = 0; i < num_partition; i++) {
		idx = blockDim.x * i + threadIdx.x;
		if (idx < len_amino_seq)
			s_amino_seq_idx[idx] = d_amino_seq_idx[idx];
	}

	num_partition = 183 / blockDim.x + 1;
	for (i = 0; i < num_partition; i++) {
		idx = blockDim.x * i + threadIdx.x;
		if (idx < 183)
			s_codons[idx] = d_codons[idx];
	}

	num_partition = 61 / blockDim.x + 1;
	for (i = 0; i < num_partition; i++) {
		idx = blockDim.x * i + threadIdx.x;
		if (idx < 61) 
			s_codons_weight[idx] = d_codons_weight[idx];
	}
	if (threadIdx.x < 20) {
		s_codons_num[threadIdx.x] = d_codons_num[threadIdx.x];
		s_amino_startpos[threadIdx.x] = d_amino_startpos[threadIdx.x];
	}
	__syncthreads();


	/* -------------------- initialize solution -------------------- */
	ptr_origin_sol = s_sol1;
	ptr_origin_objval = s_sol1_objval;
	ptr_origin_objidx = s_sol1_objidx;
	ptr_origin_lrcsval = s_sol1_lrcsval;
	
	if(blockIdx.x == 0)
	{
		num_partition = ((len_amino_seq * cds_num) % blockDim.x == 0) ? (len_amino_seq * cds_num) / blockDim.x : (len_amino_seq * cds_num) / blockDim.x + 1;
		for (i = 0; i < num_partition; i++) {
			idx = blockDim.x * i + threadIdx.x;
			if (idx < len_amino_seq * cds_num) {
				seq_idx = idx % len_amino_seq;

				pos = s_codons_num[s_amino_seq_idx[seq_idx]] - 1;

				ptr_origin_sol[idx * CODON_SIZE] = s_codons[(s_amino_startpos[s_amino_seq_idx[seq_idx]] + pos) * CODON_SIZE];
				ptr_origin_sol[idx * CODON_SIZE + 1] = s_codons[(s_amino_startpos[s_amino_seq_idx[seq_idx]] + pos) * CODON_SIZE + 1];
				ptr_origin_sol[idx * CODON_SIZE + 2] = s_codons[(s_amino_startpos[s_amino_seq_idx[seq_idx]] + pos) * CODON_SIZE + 2];
			}
		}
	}
	else {
		num_partition = ((len_amino_seq * cds_num) % blockDim.x == 0) ? (len_amino_seq * cds_num) / blockDim.x : (len_amino_seq * cds_num) / blockDim.x + 1;
		for (i = 0; i < num_partition; i++) {
			idx = blockDim.x * i + threadIdx.x;
			if (idx < len_amino_seq * cds_num) {
				seq_idx = idx % len_amino_seq;

				do {
					pos = (char)(curand_uniform(&localState) * s_codons_num[s_amino_seq_idx[seq_idx]]);
				} while (pos == s_codons_num[s_amino_seq_idx[seq_idx]]);

				ptr_origin_sol[idx * CODON_SIZE] = s_codons[(s_amino_startpos[s_amino_seq_idx[seq_idx]] + pos) * CODON_SIZE];
				ptr_origin_sol[idx * CODON_SIZE + 1] = s_codons[(s_amino_startpos[s_amino_seq_idx[seq_idx]] + pos) * CODON_SIZE + 1];
				ptr_origin_sol[idx * CODON_SIZE + 2] = s_codons[(s_amino_startpos[s_amino_seq_idx[seq_idx]] + pos) * CODON_SIZE + 2];
			}
		}
	}
	__syncthreads();


	/* calculate mCAI */
	num_partition = (len_amino_seq % blockDim.x == 0) ? (len_amino_seq / blockDim.x) : (len_amino_seq / blockDim.x) + 1;
	for (i = 0; i < cds_num; i++) {
		s_obj_compute[threadIdx.x] = 1;
		for (j = 0; j < num_partition; j++) {
			seq_idx = blockDim.x * j + threadIdx.x;
			if (seq_idx < len_amino_seq) {
				pos = FindNum_C(&s_codons[s_amino_startpos[s_amino_seq_idx[seq_idx]] * CODON_SIZE], &ptr_origin_sol[len_cds * i + seq_idx * CODON_SIZE], 
					s_codons_num[s_amino_seq_idx[seq_idx]]);
				s_obj_compute[threadIdx.x] *= pow(s_codons_weight[s_amino_startpos[s_amino_seq_idx[seq_idx]] + pos], 1.0 / len_amino_seq);
			}
		}
		__syncthreads();
	
		if (threadIdx.x == 0) {
			tmp_objval = 1;
			for (j = 0; j < blockDim.x; j++) {
				tmp_objval *= s_obj_compute[j];
			}

			if (i == 0) {
				ptr_origin_objval[_mCAI] = tmp_objval;
				ptr_origin_objidx[_mCAI * 2] = i;
			}else if (tmp_objval <= ptr_origin_objval[_mCAI]) {
				ptr_origin_objval[_mCAI] = tmp_objval;
				ptr_origin_objidx[_mCAI * 2] = i;
			}
		}
		__syncthreads();
	}

	/* calculate mHD */
	num_partition = (len_cds % blockDim.x == 0) ? (len_cds / blockDim.x) : (len_cds / blockDim.x) + 1;
	for (i = 0; i < cds_num; i++) {
		for (j = i + 1; j < cds_num; j++) {
			s_obj_compute[threadIdx.x] = 0;
			for (k = 0; k < num_partition; k++) {
				seq_idx = blockDim.x * k + threadIdx.x;
				if (seq_idx < len_cds && (ptr_origin_sol[len_cds * i + seq_idx] != ptr_origin_sol[len_cds * j + seq_idx])) {
					s_obj_compute[threadIdx.x] += 1;
				}
			}
			__syncthreads();
	
			if (threadIdx.x == 0) {
				tmp_objval = 0;
				for (k = 0; k < blockDim.x; k++) {
					tmp_objval += s_obj_compute[k];
				}
	
				if (i == 0 && j == 1) {
					ptr_origin_objval[_mHD] = tmp_objval / len_cds;
					ptr_origin_objidx[_mHD * 2] = i;
					ptr_origin_objidx[_mHD * 2 + 1] = j;
				}
				else if (tmp_objval <= ptr_origin_objval[_mHD]) {
					ptr_origin_objval[_mHD] = tmp_objval;
					ptr_origin_objidx[_mHD * 2] = i;
					ptr_origin_objidx[_mHD * 2 + 1] = j;
				}
			}
			__syncthreads();
		}
	}

	/* calculate MLRCS */
	if (threadIdx.x == 0) {
		ptr_origin_lrcsval[L] = 0;
	}
	__syncthreads();
	
	num_partition = ((len_cds + 1) % blockDim.x == 0) ? (len_cds + 1) / blockDim.x : (len_cds + 1) / blockDim.x + 1;
	for (i = 0; i < cds_num; i++) {
		for (j = i; j < cds_num; j++) {
			for (k = 0; k < len_cds + 1; k++) {
				pos = (char)(k % 2);					// distinguish s_lrcs_compute number
				
				if (i == j) {
					for (l = 0; l < num_partition; l++) {
						idx = blockDim.x * l + threadIdx.x;
						
						if (idx < len_cds + 1) {
							if (k == 0 || idx == 0 || (k == idx))
								s_lrcs_compute[pos * (len_cds + 1) + idx] = 0;
							else if (ptr_origin_sol[len_cds * i + k - 1] == ptr_origin_sol[len_cds * j + idx - 1])
								s_lrcs_compute[pos * (len_cds + 1) + idx] = s_lrcs_compute[((pos + 1) % 2) * (len_cds + 1) + idx - 1] + 1;
							else
								s_lrcs_compute[pos * (len_cds + 1) + idx] = 0;
						}
					
					}
				}
				else {
					for (l = 0; l < num_partition; l++) {
						idx = blockDim.x * l + threadIdx.x;
						
						if (idx < len_cds + 1) {
							if (k == 0 || idx == 0)
								s_lrcs_compute[pos * (len_cds + 1) + idx] = 0;
							else if (ptr_origin_sol[len_cds * i + k - 1] == ptr_origin_sol[len_cds * j + idx - 1])
								s_lrcs_compute[pos * (len_cds + 1) + idx] = s_lrcs_compute[((pos + 1) % 2) * (len_cds + 1) + idx - 1] + 1;
							else
								s_lrcs_compute[pos * (len_cds + 1) + idx] = 0;
						}
					
					}
				}
				__syncthreads();
	
				if (threadIdx.x == 0) {
					for (l = 1; l < len_cds + 1; l++) {
						if (s_lrcs_compute[pos * (len_cds + 1) + l] >= ptr_origin_lrcsval[L]) {
							ptr_origin_lrcsval[L] = s_lrcs_compute[pos * (len_cds + 1) + l];
							ptr_origin_lrcsval[P] = l - ptr_origin_lrcsval[L] + 1;
							ptr_origin_lrcsval[Q] = k - ptr_origin_lrcsval[L] + 1;
							ptr_origin_objval[_MLRCS] = (float)ptr_origin_lrcsval[L] / len_cds;
							ptr_origin_objidx[_MLRCS * 2] = i;
							ptr_origin_objidx[_MLRCS * 2 + 1] = j;
						}
					}
				}
				__syncthreads();
			}
		}
	}
	/* -------------------- end of initialize -------------------- */


	//sol_num = FIRST_SOL;
	/* mutate cycle times */
	//for (int c = 0; c < cycle; c++)
	//{
	//	if (sol_num == FIRST_SOL) {
	//ptr_origin_sol = s_sol1; 
	//ptr_origin_objval = s_sol1_objval;
	//ptr_origin_objidx = s_sol1_objidx;
	//ptr_origin_lrcsval = s_sol1_lrcsval;
	//ptr_target_sol = s_sol2;
	//ptr_target_objval = s_sol2_objval;
	//ptr_target_objidx = s_sol2_objidx;
	//ptr_target_lrcsval = s_sol2_lrcsval;
	//
	//	else {
	//ptr_origin_sol = s_sol2;
	//ptr_origin_objval = s_sol2_objval;
	//ptr_origin_objidx = s_sol2_objidx;
	//ptr_origin_lrcsval = s_sol2_lrcsval;
	//ptr_target_sol = s_sol1;
	//ptr_target_objval = s_sol1_objval;
	//ptr_target_objidx = s_sol1_objidx;
	//ptr_target_lrcsval = s_sol1_lrcsval;
	//
	//
	//	/* copy from original solution to target solution */
	//	num_partition = (len_sol % blockDim.x == 0) ? (len_sol / blockDim.x) : (len_sol / blockDim.x) + 1;
	//	for (i = 0; i < num_partition; i++)
	//	{
	//		seq_idx = blockDim.x * i + threadIdx.x;
	//		if (seq_idx < len_sol)
	//		{
	//			ptr_target_sol[seq_idx] = ptr_origin_sol[seq_idx];
	//		}
	//	}
	//
	//	/* select mutatation type */
	//	if (threadIdx.x == 0) {
	//		do {
	//			*mutation_type = (char)(curand_uniform(&localState) * 3);
	//		} while (*mutation_type == 3);
	//	}
	//	__syncthreads();
	//
	//
	//
	//	switch (*mutation_type) 
	//	{
	//	case 0:			// all random
	//		num_partition = ((len_amino_seq * cds_num) % blockDim.x == 0) ? (len_amino_seq * cds_num) / blockDim.x : (len_amino_seq * cds_num) / blockDim.x + 1;
	//		for (i = 0; i < num_partition; i++) {
	//			idx = blockDim.x * i + threadIdx.x;
	//			if (idx < len_amino_seq * cds_num) {
	//				seq_idx = idx % len_amino_seq;
	//				
	//				pos = FindNum_C(&s_codons[s_amino_startpos[s_amino_seq_idx[seq_idx]] * CODON_SIZE], &ptr_target_sol[idx * CODON_SIZE], 
	//					s_codons_num[s_amino_seq_idx[seq_idx]]);
	//				mutation(&localState, &s_codons[s_amino_startpos[s_amino_seq_idx[seq_idx]] * CODON_SIZE], &ptr_target_sol[idx * CODON_SIZE],
	//					s_codons_num[s_amino_seq_idx[seq_idx]], pos, mprob, RANDOM);
	//			}
	//		}
	//		break;
	//
	//	case 1:			// mCAI
	//		num_partition = (len_amino_seq % blockDim.x == 0) ? (len_amino_seq / blockDim.x) : (len_amino_seq / blockDim.x) + 1;
	//		for (i = 0; i < num_partition; i++) {
	//			seq_idx = blockDim.x * i + threadIdx.x;
	//			if (seq_idx < len_amino_seq) {
	//				pos = FindNum_C(&s_codons[s_amino_startpos[s_amino_seq_idx[seq_idx]] * CODON_SIZE], 
	//					&ptr_target_sol[len_cds * ptr_origin_objidx[_mCAI * 2] + seq_idx * CODON_SIZE], s_codons_num[s_amino_seq_idx[seq_idx]]);
	//				mutation(&localState, &s_codons[s_amino_startpos[s_amino_seq_idx[seq_idx]] * CODON_SIZE], 
	//					&ptr_target_sol[len_cds * ptr_origin_objidx[_mCAI * 2] + seq_idx * CODON_SIZE], s_codons_num[s_amino_seq_idx[seq_idx]], pos, mprob, UPPER);
	//			}
	//		}
	//		break;
	//
	//	case 2:			// mHD
	//		num_partition = (len_amino_seq % blockDim.x == 0) ? (len_amino_seq / blockDim.x) : (len_amino_seq / blockDim.x) + 1;
	//		for (i = 0; i < num_partition; i++) {
	//			seq_idx = blockDim.x * i + threadIdx.x;
	//			if (seq_idx < len_amino_seq) {
	//				pos = FindNum_C(&s_codons[s_amino_startpos[s_amino_seq_idx[seq_idx]] * CODON_SIZE], 
	//					&ptr_target_sol[len_cds * ptr_origin_objidx[_mHD * 2] + seq_idx * CODON_SIZE], s_codons_num[s_amino_seq_idx[seq_idx]]);
	//				mutation(&localState, &s_codons[s_amino_startpos[s_amino_seq_idx[seq_idx]] * CODON_SIZE],
	//					&ptr_target_sol[len_cds * ptr_origin_objidx[_mHD * 2] + seq_idx * CODON_SIZE], s_codons_num[s_amino_seq_idx[seq_idx]], pos, mprob, RANDOM);
	//				
	//				pos = FindNum_C(&s_codons[s_amino_startpos[s_amino_seq_idx[seq_idx]] * CODON_SIZE], 
	//					&ptr_target_sol[len_cds * ptr_origin_objidx[_mHD * 2 + 1] + seq_idx * CODON_SIZE], s_codons_num[s_amino_seq_idx[seq_idx]]);
	//				mutation(&localState, &s_codons[s_amino_startpos[s_amino_seq_idx[seq_idx]] * CODON_SIZE],
	//					&ptr_target_sol[len_cds * ptr_origin_objidx[_mHD * 2 + 1] + seq_idx * CODON_SIZE], s_codons_num[s_amino_seq_idx[seq_idx]], pos, mprob, RANDOM);
	//
	//			}
	//		}
	//		break;
	//	}
	//	__syncthreads();
	//
	//
	//	/* calculate mCAI */
	//	num_partition = (len_amino_seq % blockDim.x == 0) ? (len_amino_seq / blockDim.x) : (len_amino_seq / blockDim.x) + 1;
	//	for (i = 0; i < cds_num; i++) {
	//s_obj_compute[threadIdx.x] = 1;
	//for (j = 0; j < num_partition; j++) {
	//	seq_idx = blockDim.x * j + threadIdx.x;
	//	if (seq_idx < len_amino_seq) {
	//		pos = FindNum_C(&s_codons[s_amino_startpos[s_amino_seq_idx[seq_idx]] * CODON_SIZE], &ptr_target_sol[len_cds * i + seq_idx * CODON_SIZE],
	//			s_codons_num[s_amino_seq_idx[seq_idx]]);
	//		s_obj_compute[threadIdx.x] *= pow(s_codons_weight[s_amino_startpos[s_amino_seq_idx[seq_idx]] + pos], 1.0 / len_amino_seq);
	//	}
	//}
	//__syncthreads();
	//
	//if (threadIdx.x == 0) {
	//	tmp_objval = 1;
	//	for (j = 0; j < blockDim.x; j++) {
	//		tmp_objval *= s_obj_compute[j];
	//	}
	//
	//	if (i == 0) {
	//		ptr_target_objval[_mCAI] = tmp_objval;
	//		ptr_target_objidx[_mCAI * 2] = i;
	//	}
	//	else if (tmp_objval <= ptr_target_objval[_mCAI]) {
	//		ptr_target_objval[_mCAI] = tmp_objval;
	//		ptr_target_objidx[_mCAI * 2] = i;
	//	}
	//}
	//__syncthreads();
	//
	//
	//
	//	/* calculate mHD */
	//	num_partition = (len_cds % blockDim.x == 0) ? (len_cds / blockDim.x) : (len_cds / blockDim.x) + 1;
	//	for (i = 0; i < cds_num; i++) {
	//for (j = i + 1; j < cds_num; j++) {
	//	s_obj_compute[threadIdx.x] = 0;
	//	for (k = 0; k < num_partition; k++) {
	//		seq_idx = blockDim.x * k + threadIdx.x;
	//		if (seq_idx < len_cds && (ptr_target_sol[len_cds * i + seq_idx] != ptr_target_sol[len_cds * j + seq_idx])) {
	//			s_obj_compute[threadIdx.x] += 1;
	//		}
	//	}
	//	__syncthreads();
	//
	//	if (threadIdx.x == 0) {
	//		tmp_objval = 0;
	//		for (k = 0; k < blockDim.x; k++) {
	//			tmp_objval += s_obj_compute[k];
	//		}
	//
	//		if (i == 0 && j == 1) {
	//			ptr_target_objval[_mHD] = tmp_objval / len_cds;
	//			ptr_target_objidx[_mHD * 2] = i;
	//			ptr_target_objidx[_mHD * 2 + 1] = j;
	//		}
	//		else if (tmp_objval <= ptr_target_objval[_mHD]) {
	//			ptr_target_objval[_mHD] = tmp_objval;
	//			ptr_target_objidx[_mHD * 2] = i;
	//			ptr_target_objidx[_mHD * 2 + 1] = j;
	//		}
	//	}
	//	__syncthreads();
	//}
	//
	//
	//	if (ptr_target_objval[_mCAI] >= ptr_origin_objval[_mCAI] &&
	//		ptr_target_objval[_mHD] >= ptr_origin_objval[_mHD])
	//
	//if (sol_num == FIRST_SOL) {
	//	sol_num = SECOND_SOL;
	//}
	//else {
	//	sol_num = FIRST_SOL;
	//}
	//
	//}



	//if (sol_num == FIRST_SOL) {
	//	ptr_origin_sol = s_sol1;
	//	ptr_origin_objval = s_sol1_objval;
	//	ptr_origin_objidx = s_sol1_objidx;
	//	ptr_origin_lrcsval = s_sol1_lrcsval;
	//}
	//else {
	//	ptr_origin_sol = s_sol2;
	//	ptr_origin_objval = s_sol2_objval;
	//	ptr_origin_objidx = s_sol2_objidx;
	//	ptr_origin_lrcsval = s_sol2_lrcsval;
	//}

	/* copy from shared memory to global memory */
	num_partition = (len_sol % blockDim.x == 0) ? (len_sol / blockDim.x) : (len_sol / blockDim.x) + 1;
	for (i = 0; i < num_partition; i++) {
		idx = blockDim.x * i + threadIdx.x;
		if (idx < len_sol)
			d_pop[blockIdx.x * len_sol + idx] = ptr_origin_sol[idx];
	}

	if (threadIdx.x == 0)
	{
		d_objval[blockIdx.x * OBJECTIVE_NUM + _mCAI] = ptr_origin_objval[_mCAI];
		d_objval[blockIdx.x * OBJECTIVE_NUM + _mHD] = ptr_origin_objval[_mHD];
		d_objval[blockIdx.x * OBJECTIVE_NUM + _MLRCS] = ptr_origin_objval[_MLRCS];
	}

	return;
}



int main()
{
	srand(time(NULL));

	char input_file[32] = "Q5VZP5.fasta.txt";
	char* amino_seq;						// store amino sequences from input file
	char* h_amino_seq_idx;					// notify index of amino abbreviation array corresponding input amino sequences
	char* h_pop;							// store population (a set of solutions)
	float* h_objval;						// store objective values of population (solution 1, solution 2 .... solution n)
	char* h_amino_startpos;					// notify position of according amino abbreviation index
	int len_amino_seq, len_cds, len_sol;
	int pop_size;
	int cycle;
	int cds_num;							// size of solution equal to number of CDSs(codon sequences) in a solution
	float mprob;							// mutation probability
	int x;
	
	float lowest_mcai;						// for divide initial solution section
	
	char tmp;
	int i, j, k;
	int idx;
	char buf[256];
	FILE* fp;
	

	int numBlocks;
	int threadsPerBlock;

	char* d_amino_seq_idx;
	char* d_pop;
	float* d_objval;
	char* d_amino_startpos;
	char* d_codons;
	char* d_codons_num;
	float* d_codons_weight;
	curandStateXORWOW* genState;

	/* for time and mcai section cehck */
	cudaEvent_t d_start, d_end;
	float kernel_time;
	cudaEventCreate(&d_start);
	cudaEventCreate(&d_end);



	/* ---------------------------------------- preprocessing ---------------------------------------- */
	/* input parameter values */
	//printf("input file name : "); scanf_s("%s", &input_file);
	printf("input number of cycle : "); scanf_s("%d", &cycle);					// if number of cycle is zero we can check initial population
	if (cycle < 0) {
		printf("input max cycle value >= 0\n");
		return EXIT_FAILURE;
	}
	printf("input number of solution : "); scanf_s("%d", &pop_size);
	if (pop_size <= 0) {
		printf("input number of solution > 0\n");
		return EXIT_FAILURE;
	}
	printf("input number of CDSs in a solution : "); scanf_s("%d", &cds_num);
	if (cds_num <= 1) {
		printf("input number of CDSs > 1\n");
		return EXIT_FAILURE;
	}
	printf("input mutation probability (0 ~ 1 value) : "); scanf_s("%f", &mprob);
	if (mprob < 0 || mprob > 1) {
		printf("input mutation probability (0 ~ 1 value) : \n");
		return EXIT_FAILURE;
	}
	printf("input thread per block x value --> number of thread  warp size (32) * x : "); scanf_s("%d", &x);


	/* read input file (fasta format) */
	fopen_s(&fp, input_file, "r");
	if (fp == NULL) {
		printf("Line : %d Opening input file is failed", __LINE__);
		return EXIT_FAILURE;
	}

	fseek(fp, 0, SEEK_END);
	len_amino_seq = ftell(fp);
	fseek(fp, 0, SEEK_SET);
	fgets(buf, 256, fp);
	len_amino_seq -= ftell(fp);

	amino_seq = (char*)malloc(sizeof(char) * len_amino_seq);

	idx = 0;
	while (!feof(fp)) {
		tmp = fgetc(fp);
		if (tmp != '\n')
			amino_seq[idx++] = tmp;
	}
	amino_seq[idx] = NULL;
	len_amino_seq = idx - 1;
	len_cds = len_amino_seq * CODON_SIZE;
	len_sol = len_cds * cds_num;

	fclose(fp);
	/* end file process */

	h_amino_seq_idx = (char*)malloc(sizeof(char) * len_amino_seq);
	for (i = 0; i < len_amino_seq; i++) {
		idx = FindAminoIndex(amino_seq[i]);
		if (idx == NOT_FOUND) {
			printf("FindAminoIndex function is failed... \n");
			return EXIT_FAILURE;
		}
		h_amino_seq_idx[i] = idx;
	}

	h_amino_startpos = (char*)malloc(sizeof(char) * 20);
	h_amino_startpos[0] = 0;
	for (i = 1; i < 20; i++) {
		h_amino_startpos[i] = h_amino_startpos[i - 1] + Codons_num[i - 1];
	}

	/* caculate the smallest mCAI value */
	lowest_mcai = 1.f;
	for (i = 0; i < len_amino_seq; i++) {
		lowest_mcai *= pow(Codons_weight[h_amino_startpos[h_amino_seq_idx[i]]], 1.0 / len_amino_seq);
	}
	/* ---------------------------------------- end of preprocessing ---------------------------------------- */


	threadsPerBlock = WARP_SIZE * x;
	numBlocks = pop_size;

	/* host memory allocation */
	h_pop = (char*)malloc(sizeof(char) * pop_size * len_sol);
	h_objval = (float*)malloc(sizeof(float) * pop_size * OBJECTIVE_NUM);


	/* device memory allocation */
	cudaMalloc((void**)&genState, sizeof(curandStateXORWOW) * numBlocks * threadsPerBlock);
	cudaMalloc((void**)&d_codons, sizeof(Codons));
	cudaMalloc((void**)&d_codons_num, sizeof(Codons_num));
	cudaMalloc((void**)&d_codons_weight, sizeof(Codons_weight));
	cudaMalloc((void**)&d_amino_seq_idx, sizeof(char) * len_amino_seq);
	cudaMalloc((void**)&d_amino_startpos, sizeof(char) * 20);
	cudaMalloc((void**)&d_pop, sizeof(char) * numBlocks * len_sol);
	cudaMalloc((void**)&d_objval, sizeof(float) * numBlocks * OBJECTIVE_NUM);


	/* memory copy host to device */
	//cudaMemcpy(d_pop, h_pop, sizeof(char) * numBlocks * len_sol, cudaMemcpyHostToDevice);
	cudaMemcpy(d_amino_seq_idx, h_amino_seq_idx, sizeof(char) * len_amino_seq, cudaMemcpyHostToDevice);
	cudaMemcpy(d_amino_startpos, h_amino_startpos, sizeof(char) * 20, cudaMemcpyHostToDevice);
	cudaMemcpy(d_codons, Codons, sizeof(Codons), cudaMemcpyHostToDevice);
	cudaMemcpy(d_codons_num, Codons_num, sizeof(Codons_num), cudaMemcpyHostToDevice);
	cudaMemcpy(d_codons_weight, Codons_weight, sizeof(Codons_weight), cudaMemcpyHostToDevice);


	/* optimize kerenl call */
	setup_kernel << <numBlocks, threadsPerBlock >> > (genState, rand());

	cudaEventRecord(d_start);
	mainKernel << <numBlocks, threadsPerBlock,
		sizeof(float)* (61 + threadsPerBlock + OBJECTIVE_NUM * 2) + sizeof(int) * ((len_cds + 1) * 2 + 3 * 2) +
		sizeof(char) * (len_amino_seq + 20 + 183 + 20 + len_sol * 2 + OBJECTIVE_NUM * 2 * 2 + 1)>> >
		(genState, d_codons, d_codons_num, d_codons_weight, d_amino_seq_idx, d_amino_startpos, d_pop, d_objval, len_amino_seq, cds_num, cycle, mprob);
	cudaEventRecord(d_end);
	cudaEventSynchronize(d_end);
	cudaEventElapsedTime(&kernel_time, d_start, d_end);


	/* memory copy device to host */
	cudaMemcpy(h_pop, d_pop, sizeof(char) * numBlocks * len_sol, cudaMemcpyDeviceToHost);
	cudaMemcpy(h_objval, d_objval, sizeof(float) * numBlocks * OBJECTIVE_NUM, cudaMemcpyDeviceToHost);



	/* print solution */
	for (i = 0; i < pop_size; i++)
	{
		printf("%d solution\n", i + 1);
		for (j = 0; j < cds_num; j++) {
			printf("%d cds : ", j + 1);
			for (k = 0; k < len_cds; k++) {
				printf("%c", h_pop[len_sol * i + len_cds * j + k]);
			}
			printf("\n");
		}
		printf("\n");
	}
	
	/* print objective value */
	for (i = 0; i < pop_size; i++)
	{
		printf("%d solution\n", i + 1);
		printf("mCAI : %f mHD : %f MLRCS : %f\n", h_objval[i * OBJECTIVE_NUM + _mCAI], h_objval[i * OBJECTIVE_NUM + _mHD], h_objval[i * OBJECTIVE_NUM + _MLRCS]);
	}


	/* for computing hypervolume write file */
	//fopen_s(&fp, "test.txt", "w");
	//for (i = 0; i < pop_size; i++)
	//{
	//	fprintf(fp, "%f %f %f\n", -h_objval[i * OBJECTIVE_NUM + _mCAI], -h_objval[i * OBJECTIVE_NUM + _mHD] / 0.35, h_objval[i * OBJECTIVE_NUM + _MLRCS]);
	//}
	//fclose(fp);



	printf("\nGPU kerenl cycle time : %f second\n",  kernel_time/ 1000.f);
	printf("lowest mcai value : %f\n", lowest_mcai);


	///* check mCAI vlaue section count chekck */
	//int check_cnt[10];
	//float check_low, check_high;
	//memset(check_cnt, 0, sizeof(int) * 10);
	//for (i = 0; i < pop_size; i++) {
	//	check_low = 0;
	//	check_high = 0.1f;
	//	j = 0;
	//	while (true) {
	//		if (check_low < h_check_mcai[i] && h_check_mcai[i] <= check_high) {
	//			check_cnt[j] += 1;
	//			break;
	//		}
	//		else {
	//			check_low += 0.1f;
	//			check_high += 0.1f;
	//			j++;
	//		}
	//	}
	//}
	//check_low = 0;
	//check_high = 0.1f;
	//for (i = 0; i < 10; i++) {
	//	printf("mCAI %f <   <= %f    counting : %d\n", check_low, check_high, check_cnt[i]);
	//	check_low += 0.1f;
	//	check_high += 0.1f;
	//}
	///* end of check */



	/* free deivce memory */
	cudaFree(genState);
	cudaFree(d_codons);
	cudaFree(d_codons_num);
	cudaFree(d_codons_weight);
	cudaFree(d_amino_seq_idx);
	cudaFree(d_amino_startpos);
	cudaFree(d_pop);
	cudaFree(d_objval);

	cudaEventDestroy(d_start);
	cudaEventDestroy(d_end);

	/* free host memory */
	free(amino_seq);
	free(h_amino_seq_idx);
	free(h_amino_startpos);
	free(h_pop);
	free(h_objval);


	return EXIT_SUCCESS;
}