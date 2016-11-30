/**
 * @file matrix.c
 *
 * Implementation of the matrix library.
 */
#include <assert.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#if defined(__NVCC__)
	#include <cuda_runtime.h>
	#include "cublas_v2.h"
#elif defined(INTEL_MKL)
	#include <mkl.h>
#else
	#include <cblas.h>
	#include <lapacke.h>
#endif

#include "logger.h"
#include "matrix.h"

#ifdef __NVCC__

/**
 * Get a cuBLAS handle.
 *
 * @return cuBLAS handle
 */
cublasHandle_t cublas_handle()
{
	static int init = 1;
	static cublasHandle_t handle;

	if ( init == 1 ) {
		cublasStatus_t stat = cublasCreate(&handle);

		assert(stat == CUBLAS_STATUS_SUCCESS);
		init = 0;
	}

	return handle;
}

#endif

/**
 * Allocate a cuBLAS matrix.
 *
 * @param M
 */
void cublas_alloc_matrix(matrix_t *M)
{
#ifdef __NVCC__
	cudaError_t stat = cudaMalloc((void **)&M->data_dev, M->rows * M->cols * sizeof(precision_t));

	assert(stat == cudaSuccess);
#endif
}

/**
 * Construct a matrix.
 *
 * @param rows
 * @param cols
 * @return pointer to a new matrix
 */
matrix_t * m_initialize (const char *name, int rows, int cols)
{
	matrix_t *M = (matrix_t *)malloc(sizeof(matrix_t));
	M->name = name;
	M->rows = rows;
	M->cols = cols;
	M->data = (precision_t *)malloc(rows * cols * sizeof(precision_t));

	cublas_alloc_matrix(M);

	return M;
}

/**
 * Construct an identity matrix.
 *
 * @param rows
 * @return pointer to a new identity matrix
 */
matrix_t * m_identity (const char *name, int rows)
{
	matrix_t *M = (matrix_t *)malloc(sizeof(matrix_t));
	M->name = name;
	M->rows = rows;
	M->cols = rows;
	M->data = (precision_t *)calloc(rows * rows, sizeof(precision_t));

	int i;
	for ( i = 0; i < rows; i++ ) {
		elem(M, i, i) = 1;
	}

	cublas_alloc_matrix(M);
	m_gpu_write(M);

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- eye(%d)\n",
		       M->name, M->rows, M->cols,
		       rows);
	}

	return M;
}

/**
 * Construct a matrix of all ones.
 *
 * @param rows
 * @param cols
 * @return pointer to a new ones matrix
 */
matrix_t * m_ones(const char *name, int rows, int cols)
{
    matrix_t *M = m_initialize(name, rows, cols);

    int i, j;
    for ( i = 0; i < rows; i++ ) {
        for ( j = 0; j < cols; j++ ) {
            elem(M, i, j) = 1;
        }
    }

	m_gpu_write(M);

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- ones(%d, %d)\n",
		       M->name, M->rows, M->cols,
		       rows, cols);
	}

    return M;
}

/**
 * Generate a normally-distributed (mu, sigma) random number
 * using the Box-Muller transform.
 *
 * @param mu      mean
 * @param signma  standard deviation
 * @return normally-distributed random number
 */
precision_t rand_normal(precision_t mu, precision_t sigma)
{
	static int init = 1;
	static int generate = 0;
	static precision_t z0, z1;

	// provide a seed on the first call
	if ( init ) {
		srand48(1);
		init = 0;
	}

	// return z1 if z0 was returned in the previous call
	generate = !generate;
	if ( !generate ) {
		return z1 * sigma + mu;
	}

	// generate number pair (z0, z1), return z0
	precision_t u1 = drand48();
	precision_t u2 = drand48();

	z0 = sqrtf(-2.0 * logf(u1)) * cosf(2.0 * M_PI * u2);
	z1 = sqrtf(-2.0 * logf(u1)) * sinf(2.0 * M_PI * u2);

	return z0 * sigma + mu;
}

/**
 * Construct a matrix of normally-distributed random numbers.
 *
 * @param rows
 * @param cols
 * @return pointer to a new random matrix
 */
matrix_t * m_random (const char *name, int rows, int cols)
{
    matrix_t *M = m_initialize(name, rows, cols);

    int i, j;
    for ( i = 0; i < rows; i++ ) {
        for ( j = 0; j < cols; j++ ) {
            elem(M, i, j) = rand_normal(0, 1);
        }
    }

	m_gpu_write(M);

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- randn(%d, %d)\n",
		       M->name, M->rows, M->cols,
		       rows, cols);
	}

    return M;
}

/**
 * Construct a zero matrix.
 *
 * @param rows
 * @param cols
 * @return pointer to a new zero matrix
 */
matrix_t * m_zeros (const char *name, int rows, int cols)
{
	matrix_t *M = (matrix_t *)malloc(sizeof(matrix_t));
	M->name = name;
	M->rows = rows;
	M->cols = cols;
	M->data = (precision_t *)calloc(rows * cols, sizeof(precision_t));

	cublas_alloc_matrix(M);
	m_gpu_write(M);

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- zeros(%d, %d)\n",
		       M->name, M->rows, M->cols,
		       rows, cols);
	}

	return M;
}

/**
 * Copy a matrix.
 *
 * @param M  pointer to matrix
 * @return pointer to copy of M
 */
matrix_t * m_copy (const char *name, matrix_t *M)
{
	return m_copy_columns(name, M, 0, M->cols);
}

/**
 * Copy a range of columns in a matrix.
 *
 * @param M
 * @param i
 * @param j
 * @return pointer to copy of columns [i, j) of M
 */
matrix_t * m_copy_columns (const char *name, matrix_t *M, int i, int j)
{
	assert(0 <= i && i < j && j <= M->cols);

	matrix_t *C = m_initialize(name, M->rows, j - i);

	memcpy(C->data, &elem(M, 0, i), C->rows * C->cols * sizeof(precision_t));

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- %s(:, %d:%d) [%d,%d]\n",
		       C->name, C->rows, C->cols,
		       M->name, i + 1, j, M->rows, j - i);
	}

	return C;
}

/**
 * Copy a range of rows in a matrix.
 *
 * @param M
 * @param i
 * @param j
 * @return pointer to copy of rows [i, j) of M
 */
matrix_t * m_copy_rows (const char *name, matrix_t *M, int i, int j)
{
	assert(0 <= i && i < j && j <= M->rows);

	matrix_t *C = m_initialize(name, j - i, M->cols);

	int k;
	for ( k = 0; k < M->cols; k++ ) {
		memcpy(&elem(C, 0, k), &elem(M, i, k), (j - i) * sizeof(precision_t));
	}

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- %s(%d:%d, :) [%d,%d]\n",
		       C->name, C->rows, C->cols,
		       M->name, i + 1, j, j - i, M->cols);
	}

	return C;
}

/**
 * Deconstruct a matrix.
 *
 * @param M  pointer to matrix
 */
void m_free (matrix_t *M)
{
#ifdef __NVCC__
	cudaFree(M->data_dev);
#endif

	free(M->data);
	free(M);
}

/**
 * Write a matrix in text format to a stream.
 *
 * @param stream  pointer to file stream
 * @param M       pointer to matrix
 */
void m_fprint (FILE *stream, matrix_t *M)
{
	fprintf(stream, "%s [%d, %d]\n", M->name, M->rows, M->cols);

	int i, j;
	for ( i = 0; i < M->rows; i++ ) {
		for ( j = 0; j < M->cols; j++ ) {
			fprintf(stream, M_ELEM_FPRINT " ", elem(M, i, j));
		}
		fprintf(stream, "\n");
	}
}

/**
 * Write a matrix in binary format to a stream.
 *
 * @param stream  pointer to file stream
 * @param M       pointer to matrix
 */
void m_fwrite (FILE *stream, matrix_t *M)
{
	fwrite(&M->rows, sizeof(int), 1, stream);
	fwrite(&M->cols, sizeof(int), 1, stream);
	fwrite(M->data, sizeof(precision_t), M->rows * M->cols, stream);
}

/**
 * Read a matrix in text format from a stream.
 *
 * @param stream  pointer to file stream
 * @return pointer to new matrix
 */
matrix_t * m_fscan (FILE *stream)
{
	int rows, cols;
	fscanf(stream, "%d %d", &rows, &cols);

	matrix_t *M = m_initialize("", rows, cols);
	int i, j;
	for ( i = 0; i < rows; i++ ) {
		for ( j = 0; j < cols; j++ ) {
			fscanf(stream, M_ELEM_FSCAN, &(elem(M, i, j)));
		}
	}

	return M;
}

/**
 * Read a matrix in binary format from a stream.
 *
 * @param stream  pointer to file stream
 * @return pointer to new matrix
 */
matrix_t * m_fread (FILE *stream)
{
	int rows, cols;
	fread(&rows, sizeof(int), 1, stream);
	fread(&cols, sizeof(int), 1, stream);

	matrix_t *M = m_initialize("", rows, cols);
	fread(M->data, sizeof(precision_t), M->rows * M->cols, stream);

	return M;
}

/**
 * Copy matrix data from host memory to device memory.
 *
 * @param M
 */
void m_gpu_write (matrix_t *M)
{
#ifdef __NVCC__
	cublasHandle_t handle = cublas_handle();

	cublasStatus_t stat = cublasSetMatrix(M->rows, M->cols, sizeof(precision_t),
		M->data, M->rows,
		M->data_dev, M->rows);

	assert(stat == CUBLAS_STATUS_SUCCESS);
#endif
}

/**
 * Copy matrix data from device memory to host memory.
 *
 * @param M
 */
void m_gpu_read (matrix_t *M)
{
#ifdef __NVCC__
	cublasHandle_t handle = cublas_handle();

	cublasStatus_t stat = cublasGetMatrix(M->rows, M->cols, sizeof(precision_t),
		M->data_dev, M->rows,
		M->data, M->rows);

	assert(stat == CUBLAS_STATUS_SUCCESS);
#endif
}

/**
 * Read a column vector from an image.
 *
 * @param M      pointer to matrix
 * @param col    column index
 * @param image  pointer to image
 */
void m_image_read (matrix_t *M, int col, image_t *image)
{
	assert(M->rows == image->channels * image->height * image->width);

	int i;
	for ( i = 0; i < M->rows; i++ ) {
		elem(M, i, col) = (precision_t) image->pixels[i];
	}
}

/**
 * Write a column of a matrix to an image.
 *
 * @param M      pointer to matrix
 * @param col    column index
 * @param image  pointer to image
 */
void m_image_write (matrix_t *M, int col, image_t *image)
{
	assert(M->rows == image->channels * image->height * image->width);

	int i;
	for ( i = 0; i < M->rows; i++ ) {
		image->pixels[i] = (unsigned char) elem(M, i, col);
	}
}

/**
 * Compute the covariance matrix of a matrix M, whose
 * columns are random variables and whose rows are
 * observations.
 *
 * If the columns of M are observations and the rows
 * of M are random variables, the covariance is:
 *
 *   C = 1/(N - 1) (M - mu * 1_N') (M - mu * 1_N')', N = M->cols
 *
 * If the columns of M are random variables and the
 * rows of M are observations, the covariance is:
 *
 *   C = 1/(N - 1) (M - 1_N * mu)' (M - 1_N * mu), N = M->rows
 *
 * @param M  pointer to matrix
 * @return pointer to covariance matrix of M
 */
matrix_t * m_covariance (const char *name, matrix_t *M)
{
	// compute A = M - 1_N * mu
	matrix_t *A = m_copy("A", M);
	matrix_t *mu = m_mean_row("mu", A);

	m_subtract_rows(A, mu);

	// compute C = 1/(N - 1) * A' * A
	matrix_t *C = m_product(name, A, A, true, false);

	precision_t c = (M->rows > 1)
		? M->rows - 1
		: 1;
	m_elem_mult(C, 1 / c);

	// cleanup
	m_free(A);
	m_free(mu);

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- cov(%s [%d,%d])\n",
		       C->name, C->rows, C->cols,
		       M->name, M->rows, M->cols);
	}

	return C;
}

/**
 * Compute the diagonal matrix of a vector.
 *
 * @param v  pointer to vector
 * @return pointer to diagonal matrix of v
 */
matrix_t * m_diagonalize (const char *name, matrix_t *v)
{
	assert(v->rows == 1 || v->cols == 1);

	int n = (v->rows == 1)
		? v->cols
		: v->rows;
    matrix_t *D = m_zeros(name, n, n);

    int i;
    for ( i = 0; i < n; i++ ) {
        elem(D, i, i) = v->data[i];
    }

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- diag(%s [%d,%d])\n",
		       D->name, D->rows, D->cols,
		       v->name, v->rows, v->cols);
	}

    return D;
}

/**
 * Compute the COS distance between two column vectors.
 *
 * COS is the cosine angle:
 * d_cos(x, y) = -x * y / (||x|| * ||y||)
 *
 * @param A  pointer to matrix
 * @param i  column index of A
 * @param B  pointer to matrix
 * @param j  column index of B
 * @return COS distance between A_i and B_j
 */
precision_t m_dist_COS (matrix_t *A, int i, matrix_t *B, int j)
{
	assert(A->rows == B->rows);

	// compute x * y
	precision_t x_dot_y = 0;

	int k;
	for ( k = 0; k < A->rows; k++ ) {
		x_dot_y += elem(A, k, i) * elem(B, k, j);
	}

	// compute ||x|| and ||y||
	precision_t abs_x = 0;
	precision_t abs_y = 0;

	for ( k = 0; k < A->rows; k++ ) {
		abs_x += elem(A, k, i) * elem(A, k, i);
		abs_y += elem(B, k, j) * elem(B, k, j);
	}

	// compute distance
	precision_t dist = -x_dot_y / sqrtf(abs_x * abs_y);

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: d_COS(%s(:, %d) [%d,%d], %s(:, %d) [%d,%d]) = %g\n",
		       A->name, i + 1, A->rows, 1,
		       B->name, j + 1, B->rows, 1,
		       dist);
	}

	return dist;
}

/**
 * Compute the L1 distance between two column vectors.
 *
 * L1 is the Taxicab distance:
 * d_L1(x, y) = |x - y|
 *
 * @param A  pointer to matrix
 * @param i  column index of A
 * @param B  pointer to matrix
 * @param j  column index of B
 * @return L1 distance between A_i and B_j
 */
precision_t m_dist_L1 (matrix_t *A, int i, matrix_t *B, int j)
{
	assert(A->rows == B->rows);

	precision_t dist = 0;

	int k;
	for ( k = 0; k < A->rows; k++ ) {
		dist += fabsf(elem(A, k, i) - elem(B, k, j));
	}

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: d_L1(%s(:, %d) [%d,%d], %s(:, %d) [%d,%d]) = %g\n",
		       A->name, i + 1, A->rows, 1,
		       B->name, j + 1, B->rows, 1,
		       dist);
	}

	return dist;
}

/**
 * Compute the L2 distance between two column vectors.
 *
 * L2 is the Euclidean distance:
 * d_L2(x, y) = ||x - y||
 *
 * @param A  pointer to matrix
 * @param i  column index of A
 * @param B  pointer to matrix
 * @param j  column index of B
 * @return L2 distance between A_i and B_j
 */
precision_t m_dist_L2 (matrix_t *A, int i, matrix_t *B, int j)
{
	assert(A->rows == B->rows);

	precision_t dist = 0;

	int k;
	for ( k = 0; k < A->rows; k++ ) {
		precision_t diff = elem(A, k, i) - elem(B, k, j);
		dist += diff * diff;
	}

	dist = sqrtf(dist);

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: d_L2(%s(:, %d) [%d,%d], %s(:, %d) [%d,%d]) = %g\n",
		       A->name, i + 1, A->rows, 1,
		       B->name, j + 1, B->rows, 1,
		       dist);
	}

	return dist;
}

/**
 * Compute the eigenvalues and eigenvectors of a symmetric matrix.
 *
 * The eigenvalues are returned as a diagonal matrix, and the
 * eigenvectors are returned as column vectors. The i-th
 * eigenvalue corresponds to the i-th column vector. The eigenvalues
 * are returned in ascending order.
 *
 * @param M
 * @param p_V
 * @param p_D
 */
void m_eigen (const char *name_V, const char *name_D, matrix_t *M, matrix_t **p_V, matrix_t **p_D)
{
	assert(M->rows == M->cols);

	static precision_t EPSILON = 1e-8;

	matrix_t *V_temp1 = m_copy(name_V, M);
	matrix_t *D_temp1 = m_initialize(name_D, M->rows, 1);

	// solve A * x = lambda * x
#ifdef __NVCC__
	// TODO: stub
#else
	int info = LAPACKE_ssyev(LAPACK_COL_MAJOR, 'V', 'U',
		M->cols, V_temp1->data, M->rows,  // input matrix (eigenvectors)
		D_temp1->data);                   // eigenvalues
	assert(info == 0);
#endif

	// remove eigenvalues <= 0
	int i = 0;
	while ( i < D_temp1->rows && elem(D_temp1, i, 0) < EPSILON ) {
		i++;
	}

	matrix_t *V = m_copy_columns(name_V, V_temp1, i, V_temp1->cols);
	matrix_t *D_temp2 = m_copy_rows(name_D, D_temp1, i, D_temp1->rows);

	// diagonalize eigenvalues
	matrix_t *D = m_diagonalize(name_D, D_temp2);

	// cleanup
	m_free(V_temp1);
	m_free(D_temp1);
	m_free(D_temp2);

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d], %s [%d,%d] <- eig(%s [%d,%d])\n",
		       V->name, V->rows, V->cols,
		       D->name, D->rows, D->cols,
		       M->name, M->rows, M->cols);
	}

	// save outputs
	*p_V = V;
	*p_D = D;
}

/**
 * Compute the generalized eigenvalues and eigenvectors of two
 * symmetric matrices. The matrix B is also assumed to be positive
 * definite.
 *
 * The eigenvalues are returned as a diagonal matrix, and the
 * eigenvectors are returned as column vectors. The i-th
 * eigenvalue corresponds to the i-th column vector. The eigenvalues
 * are returned in ascending order.
 *
 * @param A
 * @param B
 * @param p_V
 * @param p_D
 */
void m_eigen2 (const char *name_V, const char *name_D, matrix_t *A, matrix_t *B, matrix_t **p_V, matrix_t **p_D)
{
	assert(A->rows == A->cols && B->rows == B->cols);
	assert(A->rows == B->rows);

	matrix_t *V = m_copy(name_V, A);
	matrix_t *D_temp1 = m_initialize(name_D, A->rows, 1);

	// solve A * x = lambda * B * x
#ifdef __NVCC__
	// TODO: stub
#else
	matrix_t *B_work = m_copy("B", B);

	int info = LAPACKE_ssygv(LAPACK_COL_MAJOR, 1, 'V', 'U',
		A->cols, V->data, A->rows,  // left input matrix (eigenvectors)
		B_work->data, B->rows,      // right input matrix
		D_temp1->data);             // eigenvalues
	assert(info == 0);

	m_free(B_work);
#endif

	// diagonalize eigenvalues
	matrix_t *D = m_diagonalize(name_D, D_temp1);

	// cleanup
	m_free(D_temp1);

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d], %s [%d,%d] <- eig(%s [%d,%d], %s [%d,%d])\n",
		       V->name, V->rows, V->cols,
		       D->name, D->rows, D->cols,
		       A->name, A->rows, A->cols,
		       B->name, B->rows, B->cols);
	}

	// save outputs
	*p_V = V;
	*p_D = D;
}

/**
 * Compute the inverse of a square matrix.
 *
 * @param M  pointer to matrix
 * @return pointer to new matrix equal to M^-1
 */
matrix_t * m_inverse (const char *name, matrix_t *M)
{
	assert(M->rows == M->cols);

	matrix_t *M_inv = m_copy(name, M);

#ifdef __NVCC__
	// TODO: stub
#else
	int *ipiv = (int *)malloc(M->cols * sizeof(int));

	int info = LAPACKE_sgetrf(LAPACK_COL_MAJOR,
		M->rows, M->cols, M_inv->data, M->rows,
		ipiv);
	assert(info == 0);

	info = LAPACKE_sgetri(LAPACK_COL_MAJOR,
		M->cols, M_inv->data, M->rows,
		ipiv);
	assert(info == 0);

	free(ipiv);
#endif

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- inv(%s [%d,%d])\n",
		       M_inv->name, M_inv->rows, M_inv->cols,
		       M->name, M->rows, M->cols);
	}

	return M_inv;
}

/**
 * Get the mean column of a matrix.
 *
 * @param M  pointer to matrix
 * @return pointer to mean column vector
 */
matrix_t * m_mean_column (const char *name, matrix_t *M)
{
	matrix_t *a = m_zeros(name, M->rows, 1);

	int i, j;
	for ( i = 0; i < M->cols; i++ ) {
		for ( j = 0; j < M->rows; j++ ) {
			elem(a, j, 0) += elem(M, j, i);
		}
	}

	m_elem_mult(a, 1.0f / M->cols);

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- mean(%s [%d,%d], 2)\n",
		       a->name, a->rows, a->cols,
		       M->name, M->rows, M->cols);
	}

	return a;
}

/**
 * Get the mean row of a matrix.
 *
 * @param M  pointer to matrix
 * @return pointer to mean row vector
 */
matrix_t * m_mean_row (const char *name, matrix_t *M)
{
	matrix_t *a = m_zeros(name, 1, M->cols);

	int i, j;
	for ( i = 0; i < M->rows; i++ ) {
		for ( j = 0; j < M->cols; j++ ) {
			elem(a, 0, j) += elem(M, i, j);
		}
	}

	m_elem_mult(a, 1.0f / M->rows);

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- mean(%s [%d,%d], 1)\n",
		       a->name, a->rows, a->cols,
		       M->name, M->rows, M->cols);
	}

	return a;
}

/**
 * Compute the 2-norm of a vector.
 *
 * @param v  pointer to vector
 * @return 2-norm of v
 */
precision_t m_norm(matrix_t *v)
{
	assert(v->rows == 1 || v->cols == 1);

	int N = (v->rows == 1)
		? v->cols
		: v->rows;
	int incX = 1;

	precision_t norm;

#ifdef __NVCC__
	cublasHandle_t handle = cublas_handle();

	cublasStatus_t stat = cublasSnrm2(handle, N, v->data_dev, incX, &norm);

	assert(stat == CUBLAS_STATUS_SUCCESS);
#else
	norm = cblas_snrm2(N, v->data, incX);
#endif

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: norm(%s [%d,%d]) = %g\n",
		       v->name, v->rows, v->cols,
		       norm);
	}

	return norm;
}

/**
 * Get the product of two matrices.
 *
 * @param A
 * @param B
 * @param transA
 * @param transB
 * @return pointer to new matrix equal to A * B
 */
matrix_t * m_product (const char *name, matrix_t *A, matrix_t *B, bool transA, bool transB)
{
	int M = transA ? A->cols : A->rows;
	int K = transA ? A->rows : A->cols;
	int K2 = transB ? B->cols : B->rows;
	int N = transB ? B->rows : B->cols;

	assert(K == K2);

	matrix_t *C = m_zeros(name, M, N);

	precision_t alpha = 1;
	precision_t beta = 0;

	// C := alpha * A * B + beta * C
#ifdef __NVCC__
	cublasHandle_t handle = cublas_handle();
	cublasOperation_t transa = transA
		? CUBLAS_OP_T
		: CUBLAS_OP_N;
	cublasOperation_t transb = transB
		? CUBLAS_OP_T
		: CUBLAS_OP_N;

	cublasStatus_t stat = cublasSgemm(handle, transa, transb,
		M, N, K,
		&alpha, A->data_dev, A->rows, B->data_dev, B->rows,
		&beta, C->data_dev, C->rows);

	assert(stat == CUBLAS_STATUS_SUCCESS);
#else
	CBLAS_TRANSPOSE TransA = transA
		? CblasTrans
		: CblasNoTrans;
	CBLAS_TRANSPOSE TransB = transB
		? CblasTrans
		: CblasNoTrans;

	cblas_sgemm(CblasColMajor, TransA, TransB,
		M, N, K,
		alpha, A->data, A->rows, B->data, B->rows,
		beta, C->data, C->rows);
#endif

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- %s%s [%d,%d] * %s%s [%d,%d]\n",
		       C->name, M, N,
		       A->name, transA ? "'" : "", M, K,
		       B->name, transB ? "'" : "", K, N);
	}

	return C;
}

/**
 * Compute the principal square root of a symmetric matrix. That
 * is, compute X such that X * X = M and X is the unique square root
 * for which every eigenvalue has non-negative real part.
 *
 * @param M  pointer to symmetric matrix
 * @return pointer to square root matrix
 */
matrix_t * m_sqrtm (const char *name, matrix_t *M)
{
	assert(M->rows == M->cols);

	// compute [V, D] = eig(M)
	matrix_t *V;
	matrix_t *D;

	m_eigen("V", "D", M, &V, &D);

	// compute B = V * sqrt(D)
	m_elem_apply(D, sqrtf);

	matrix_t *B = m_product("B", V, D);

	// compute X = B * V'
	matrix_t *X = m_product(name, B, V, false, true);

	// cleanup
	m_free(B);
	m_free(V);
	m_free(D);

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- sqrtm(%s [%d,%d])\n",
		       X->name, X->rows, X->cols,
		       M->name, M->rows, M->cols);
	}

	return X;
}

/**
 * Get the transpose of a matrix.
 *
 * NOTE: This function should not be necessary since
 * most transposes should be handled by m_product().
 *
 * @param M  pointer to matrix
 * @return pointer to new transposed matrix
 */
matrix_t * m_transpose (const char *name, matrix_t *M)
{
	matrix_t *T = m_initialize(name, M->cols, M->rows);

	int i, j;
	for ( i = 0; i < T->rows; i++ ) {
		for ( j = 0; j < T->cols; j++ ) {
			elem(T, i, j) = elem(M, j, i);
		}
	}

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- transpose(%s [%d,%d])\n",
		       T->name, T->rows, T->cols,
		       M->name, M->rows, M->cols);
	}

	return T;
}

/**
 * Add a matrix to another matrix.
 *
 * @param A
 * @param B
 */
void m_add (matrix_t *A, matrix_t *B)
{
	assert(A->rows == B->rows && A->cols == B->cols);

	int N = A->rows * A->cols;
	precision_t alpha = 1.0f;
	int incX = 1;
	int incY = 1;

#ifdef __NVCC__
	cublasHandle_t handle = cublas_handle();

	cublasStatus_t stat = cublasSaxpy(handle, N, &alpha,
		B->data_dev, incX,
		A->data_dev, incY);

	assert(stat == CUBLAS_STATUS_SUCCESS);
#else
	cblas_saxpy(N, alpha, B->data, incX, A->data, incY);
#endif

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- %s [%d,%d] + %s [%d,%d]\n",
		       A->name, A->rows, A->cols,
		       A->name, A->rows, A->cols,
		       B->name, B->rows, B->cols);
	}
}

/**
 * Assign a column of a matrix.
 *
 * @param A  pointer to matrix
 * @param i  lhs column index
 * @param B  pointer to matrix
 * @param j  rhs column index
 */
void m_assign_column (matrix_t * A, int i, matrix_t * B, int j)
{
    assert(A->rows == B->rows);
    assert(0 <= i && i < A->cols);
    assert(0 <= j && j < B->cols);

    memcpy(&elem(A, 0, i), B->data, B->rows * sizeof(precision_t));

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s(:, %d) [%d,%d] <- %s(:, %d) [%d,%d]\n",
		       A->name, i + 1, A->rows, 1,
		       B->name, j + 1, B->rows, 1);
	}
}

/**
 * Assign a row of a matrix.
 *
 * @param A  pointer to matrix
 * @param i  lhs row index
 * @param B  pointer to matrix
 * @param j  rhs row index
 */
void m_assign_row (matrix_t * A, int i, matrix_t * B, int j)
{
    assert(A->cols == B->cols);
    assert(0 <= i && i < A->rows);
    assert(0 <= j && j < B->rows);

    int k;
    for ( k = 0; k < A->cols; k++ ) {
        elem(A, i, k) = elem(B, j, k);
    }

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s(%d, :) [%d,%d] <- %s(%d, :) [%d,%d]\n",
		       A->name, i + 1, 1, A->cols,
		       B->name, j + 1, 1, B->cols);
	}
}

/**
 * Subtract a matrix from another matrix.
 *
 * @param A
 * @param B
 */
void m_subtract (matrix_t *A, matrix_t *B)
{
	assert(A->rows == B->rows && A->cols == B->cols);

	int N = A->rows * A->cols;
	precision_t alpha = -1.0f;
	int incX = 1;
	int incY = 1;

#ifdef __NVCC__
	cublasHandle_t handle = cublas_handle();

	cublasStatus_t stat = cublasSaxpy(handle, N, &alpha,
		B->data_dev, incX,
		A->data_dev, incY);

	assert(stat == CUBLAS_STATUS_SUCCESS);
#else
	cblas_saxpy(N, alpha, B->data, incX, A->data, incY);
#endif

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- %s [%d,%d] - %s [%d,%d]\n",
		       A->name, A->rows, A->cols,
		       A->name, A->rows, A->cols,
		       B->name, B->rows, B->cols);
	}
}

/**
 * Apply a function to each element of a matrix.
 *
 * @param M  pointer to a matrix
 * @param f  pointer to element-wise function
 */
void m_elem_apply (matrix_t * M, elem_func_t f)
{
    int i, j;

    for ( i = 0; i < M->rows; i++ ) {
        for ( j = 0; j < M->cols; j++ ) {
            elem(M, i, j) = f(elem(M, i, j));
        }
    }

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- f(%s [%d,%d])\n",
		       M->name, M->rows, M->cols,
		       M->name, M->rows, M->cols);
	}
}

/**
 * Multiply a matrix by a scalar.
 *
 * @param M  pointer to matrix
 * @param c  scalar
 */
void m_elem_mult (matrix_t *M, precision_t c)
{
	int N = M->rows * M->cols;
	int incX = 1;

#ifdef __NVCC__
	cublasHandle_t handle = cublas_handle();

	cublasStatus_t stat = cublasSscal(handle, N, &c, M->data_dev, incX);

	assert(stat == CUBLAS_STATUS_SUCCESS);
#else
	cblas_sscal(N, c, M->data, incX);
#endif

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- %g * %s [%d,%d]\n",
		       M->name, M->rows, M->cols,
		       c, M->name, M->rows, M->cols);
	}
}

/**
 * Shuffle the columns of a matrix.
 *
 * @param M  pointer to matrix
 */
void m_shuffle_columns (matrix_t *M)
{
	precision_t *temp = (precision_t *)malloc(M->rows * sizeof(precision_t));

	int i, j;
	for ( i = 0; i < M->cols - 1; i++ ) {
		// generate j such that i <= j < M->cols
		j = rand() % (M->cols - i) + i;

		// swap columns i and j
		if ( i != j ) {
			memcpy(temp, &elem(M, 0, i), M->rows * sizeof(precision_t));
			memcpy(&elem(M, 0, i), &elem(M, 0, j), M->rows * sizeof(precision_t));
			memcpy(&elem(M, 0, j), temp, M->rows * sizeof(precision_t));
		}
	}

	free(temp);

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- %s(:, randperm(size(%s, 2))) [%d,%d]\n",
		       M->name, M->rows, M->cols,
		       M->name, M->name, M->rows, M->cols);
	}
}

/**
 * Subtract a column vector from each column in a matrix.
 *
 * This function is equivalent to:
 *
 *   M = M - a * 1_N'
 *
 * @param M  pointer to matrix
 * @param a  pointer to column vector
 */
void m_subtract_columns (matrix_t *M, matrix_t *a)
{
	assert(M->rows == a->rows && a->cols == 1);

	int i, j;
	for ( i = 0; i < M->cols; i++ ) {
		for ( j = 0; j < M->rows; j++ ) {
			elem(M, j, i) -= elem(a, j, 0);
		}
	}

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- %s [%d,%d] - %s [%d,%d] * %s [%d,%d]\n",
		       M->name, M->rows, M->cols,
		       M->name, M->rows, M->cols,
		       a->name, a->rows, a->cols,
		       "1_N'", 1, M->cols);
	}
}

/**
 * Subtract a row vector from each row in a matrix.
 *
 * This function is equivalent to:
 *
 *   M = M - 1_N * a
 *
 * @param M  pointer to matrix
 * @param a  pointer to row vector
 */
void m_subtract_rows (matrix_t *M, matrix_t *a)
{
	assert(M->cols == a->cols && a->rows == 1);

	int i, j;
	for ( i = 0; i < M->rows; i++ ) {
		for ( j = 0; j < M->cols; j++ ) {
			elem(M, i, j) -= elem(a, 0, j);
		}
	}

	// print debug information
	if ( LOGGER(LL_DEBUG) ) {
		printf("debug: %s [%d,%d] <- %s [%d,%d] - %s [%d,%d] * %s [%d,%d]\n",
		       M->name, M->rows, M->cols,
		       M->name, M->rows, M->cols,
		       "1_N", M->rows, 1,
		       a->name, a->rows, a->cols);
	}
}
