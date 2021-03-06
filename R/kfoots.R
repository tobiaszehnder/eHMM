#' Models for multivariate count data
#' Fit mixture model or a hidden markov model
#'
#' @param counts matrix of non-negative integers. Columns represent datapoints and rows
#'     dimensions 
#' @param k either the desired number of cluster, or a specific initial
#'     value for the models (mixture components or emission probabilities).
#'     See the item \code{models} in the return values to see how the
#'     model parameters should be formatted
#' @param framework Switches between a mixture model and a hidden markov model.
#'     The default is a hidden markov model, where the order of the datapoints
#'     matters.
#' @param mix_coeff In the \code{MM} mode, initial value for the mixture 
#' coefficients. In the \code{HMM} mode it will be ignored.
#' @param trans In the \code{HMM} mode, initial value for the transition
#'     probabilities as a square matrix. The rows are the 'state from' and 
#'     the columns are the 'state to', so each rows must sum up to 1. 
#'     In the \code{HMM} mode it will be ignored.
#' @param initP In the \code{HMM} mode, initial probabilities for each 
#'     sequence of observation. They must be formatted as a matrix where 
#'     each row is a state and each column is a sequence.
#' @param tol Tolerance value used to determine convergence of the EM
#'     algorithm. The algorithm will converge when the absolute difference
#'     in the log-likelihood between two iterations will fall below this value.
#' @param maxiter maximum number of iterations in the EM algorithm. Use 0 if 
#'     you don't want to do any training iteration.
#' @param nthreads number of threads used. The backward-forward step in the HMM learning
#'     cannot use more threads than the number of sequences.
#' @param nbtype type of training for the negative binomial. Accepted types are:
#'     \code{indep}, \code{dep}, \code{pois}, \code{lognormal}. The first type corresponds to standard
#'     maximum likelihood estimates for each parameter of each model, the second one
#'     forces the \code{r} dispersion parameters of the negative multinomials to be the same
#'     for all models, the third one forces \code{r} to be infinity, that is, every model
#'     will be a Poisson distribution. The fourth corresponds to a lognormal distribution.
#' @param init Initialization scheme for the models (mixture components or emission
#'     probabilities). The value \code{rnd} results in parameters being chosen randomly,
#'     the values \code{counts, pca} use an initialization algorithm that starts from
#'     \code{init.nlev*nrow(counts)} clusters and reduces them to \code{k} using
#'     hierachical clustering.
#' @param init.nlev Tuning parameter for the initialization schemes \code{counts, pca}.
#' @param verbose print some output during execution
#' @param seqlens Length of each sequence of observations. The number of columns
#'     of the count matrix should equal \code{sum(seqlens)}.
#' @param endstate Vector of state numbers allowed to occur at the last position.
#'     If an endstate is given, the trainMode is set to viterbi.
#' @param labels vector with state labels.
#' @param trainMode Choose between viterbi and baum-welch training mode (default: baum-welch)
#' @param fix_emisP set this flag if training should only affect transition probabilities (emission probabilities will be fixed)
#' @param split4speed Add artificial breaks to speed-up the forward-backward
#'     algorithm. If \code{framework=="HMM"} and if multiple threads are used,
#'     the count matrix, which is already split according to \code{seqlens}, is
#'     split even further so that each thread can be assigned an equal amount
#'     of observations in the forward-backward algorithm. These artificial breaks
#'     usually have a small impact in the final parameters, and they improve the
#'     scalability with the number of cores, especially when the number of sequences
#'     is small compared to the number of cores. The artificial breaks are 
#'     removed after the training phase for computing the final state assignments. 
#' @return a list with, among other, the following parameters:
#'     \item{models}{a list containing the parameters of each model
#'     (mixture components or emission probabilities). Each element of 
#'     the list describes a negative multinomial distribution.
#' This is specified in another list with items \code{mu}, \code{r} and \code{ps}. \code{mu} and
#'         \code{r} correspond to parameters \code{mu} and \code{size} in the R-function \code{\link{dnbinom}}.
#'         Ps specifies the parameters of the multinomial and they sum up to 1.}
#'     \item{loglik}{the log-likelihood of the whole dataset.}
#'    \item{posteriors}{A matrix of size \code{length(models)*ncol(counts)} containing the posterior
#'            probability that a given datapoint is generated by the given mixture component}
#'     \item{states}{An integer vector of length \code{ncol(counts)} saying
#'         which model each column is associated to (using the posterior decoding
#'         algorithm).}
#'    \item{converged}{\code{TRUE} if the algorithm converged in the given number of iterations, \code{FALSE} otherwise}
#'    \item{llhistory}{time series containing the log-likelihood of the
#'        whole dataset across iterations}
#'     \item{viterbi}{In HMM mode, the viterbi path an its likelihood as a list.}
#' @export
kfoots <- function(counts, k, framework=c("HMM", "MM"), mix_coeff=NULL, trans=NULL, initP=NULL, tol = 1e-4, maxiter=200, nthreads=1, 
                   nbtype=c("dep","indep","pois","lognormal"), init=c("pca", "counts", "rnd"), init.nlev=20, verbose=TRUE, seqlens=ncol(counts), 
                   split4speed=FALSE, endstate=as.numeric(NULL), trainMode="baum-welch", fix_emisP=FALSE, notrain=FALSE, labels){
  if (nthreads < 0) {
    warning("non-positive value provided for variable 'nthreads', using 1 thread")
    nthreads <- 1
  }
  if (!is.matrix(counts))
    stop("invalid counts variable provided. It must be a matrix")
  if (nbtype == 'lognormal') storage.mode(counts) <- 'double'
  else storage.mode(counts) <- "integer" #all floating point numbers will be "floored" (not rounded)
  framework <- match.arg(framework)
  nbtype <- match.arg(nbtype)
  init <- match.arg(init)
  
  models <- NULL
  if (!is.numeric(k)){
    if (!is.list(k)){
      stop("Invalid input value for k, provide the desired number of models or a list with their initial parameters")
    }
    models <- k
    k <- length(models)
  }

  # length of seqlens vector represents the number of sequences
  nseq <- length(seqlens)
  #rows of the count matrix represent positions of the foot/histone marks
  footlen <- nrow(counts)
  #columns of the count matrix represent genomic loci
  nloci <- ncol(counts)
  #precompute some stuff for optimization
  ucs <- mapToUnique(colSumsInt(counts, nthreads))
  mConst <- getMultinomConst(counts, nthreads)
  
  if (framework=="HMM"){
    #make sure that the seqlens argument is all right
    if (any(seqlens < 0)) stop("sequence lengths must be positive")
    seqlens <- seqlens[seqlens>0]
    if (sum(seqlens) < nloci){
      warning("the provided seqlens do not add up to the total input length (ncol(counts)), adding a chunk to cover all the input")
      seqlens[length(seqlens)+1] <- nloci - sum(seqlens)
    } else if (sum(seqlens) > nloci){
      stop("invalid value for seqlens, the chunks sum up to more than the total input length")
    }
  }
  
  #set models
  if (is.null(models)){
    if (init=="rnd"){
      #get initial random models
      models <- rndModels(counts, k, bgr_prior=0.5, ucs=ucs, nbtype=nbtype, nthreads=nthreads)
    } else {
      #use initialization algorithm. It will also provide values for the 
      #mixture coefficient (framework=="MM") or the init probabilities and
      #transition probabilities (framework=="HMM"), unless these are already set
      # init.nlev <- 2
      init <- initAlgo(counts, k, nlev=init.nlev, nbtype=nbtype, nthreads=nthreads, axes=init, verbose=verbose)
      models <- init$models
      if (framework=="HMM"){
        if (is.null(trans)) trans <- t(sapply(1:k, function(i) init$mix_coeff))
        if (is.null(initP)) initP <- matrix(nrow=k, rep(init$mix_coeff, length(seqlens)))
      } else {#(framework=="MM")
        if (is.null(mix_coeff)) mix_coeff <- init$mix_coeff
      }
    }
    nbtype_input_check <- nbtype
  } else { nbtype_input_check <- "indep" }
  #make sure that the provided (or computed) models are all right
  # checkModels(models, k, footlen, nbtype_input_check)
  #set framework probabilities
  if (framework=="HMM"){
    #make sure that the init and the transition probabilities are all right
    if (is.null(trans)) {
      trans <- matrix(rep(1/k, k*k), ncol=k)
    } else if (is.matrix(trans) && (ncol(trans) != k || nrow(trans) != k)) {
      stop("'trans' must be a k*k transition matrix")
    } else if (!is.matrix(trans)){
      stop("'trans' must be a matrix")
    } 
    if (!all(apply(trans, 1, isProbVector))) stop("'trans' rows must sum up to 1")
    
    # save 'forbidden' (i.e. zero probability) transitions for later during updating transP
    # (e.g. only add pseudo-observations for 'allowed' but 'never visited' states)
    forbiddenTransitions <- which(trans == 0)
    
    if (is.null(initP)) {
      initP <- matrix(rep(1/k, k*length(seqlens)), ncol=length(seqlens))
    } else if (is.vector(initP)&&!is.matrix(initP)&&length(seqlens)==1&&length(initP)==k){
      initP <- matrix(initP, ncol=1)
    } else if (is.matrix(initP) && (nrow(initP)!=k || ncol(initP)!=length(seqlens))){
      stop("invalid 'initP' matrix provided: one column per sequence and one row per model")
    } else if (!is.matrix(initP)){
      stop("'initP' must be a matrix, or a vector if there is only one sequence")
    }
    if (!all(apply(initP, 2, isProbVector))) stop("'initP' columns must sum up to 1")
    if (split4speed){
      s4s <- refineSplits(seqlens, nthreads)
      seqlens <- s4s$newlens
      new_initP <- matrix(1/k, nrow=k, ncol=length(seqlens))
      new_initP[,s4s$origstarts] <- initP
      initP <- new_initP
    } else if (length(seqlens)<nthreads && verbose){
      message("less sequences than threads, use option 'split4speed' to take fully advantage of all threads")
    }
    
  } else {#(framework == "MM")
    #make sure that the mixture coefficients are all right
    if (is.null(mix_coeff)){
      mix_coeff = rep(1/k, k)
    } else if (!isProbVector(mix_coeff)) {
      stop("'mix_coeff' must sum up to 1")
    }
  }
  
  #allocating memory
  posteriors <- matrix(0, nrow=k, ncol=nloci)
  lliks <- matrix(0, nrow=k, ncol=nloci)
  vscores <- matrix(0, nrow=k, ncol=nloci)
  # escore <- rep(-Inf, times=nloci)
  loglik <- NA
  converged <- FALSE
  llhistory <- numeric(maxiter)
  tryCatch({
    #MAIN LOOP
    if (maxiter > 0 && verbose) cat("starting main loop\n")
    for (iter in safeSeq(1, maxiter)){
      #get log likelihoods
      if (nbtype == 'lognormal') {fittype <- 'lognormal'} else {fittype <- 'negmultinom'}
      if (fix_emisP == F || iter == 1){ # don't recalculate lliks from new emisP if fix_emisP is set and iteration is bigger than 1
        lLikMat(lliks=lliks, counts, models, ucs=ucs, mConst=mConst, nthreads=nthreads, type=fittype)
      }

      if (trainMode=="baum-welch") {
        #get posterior probabilities and train framework probabilities
        if (framework=="HMM"){
          res <- forward_backward(posteriors=posteriors, initP, trans, lliks, seqlens, nthreads=nthreads)
          new_loglik <- res$tot_llik
          new_trans <- res$new_trans
          new_initP <- res$new_initP
        } else {#framework == "MM"
          res <- llik2posteriors(posteriors=posteriors, lliks, mix_coeff, nthreads=nthreads)
          
          new_loglik <- res$tot_llik
          new_mix_coeff <- res$new_mix_coeff
        }
      }
      else if (trainMode=="viterbi"){
        if (framework=="HMM"){
          res <- viterbi(vscores=vscores, initP, trans, lliks, seqlens, endstate)
          new_loglik <- res$vllik
          vscores <- res$vscores
          vpath <- res$vpath
          vpath_split <- split(vpath, rep(1:nseq, seqlens)) # split vpath into sequences
          # calculate new transition matrix: count transitions in viterbi decoded state path
          vtrans <- matrix(0, nrow=k, ncol=k)
          for (i in 1:nseq){
            vpath_seq <- vpath_split[[i]]
            for (j in 1:(length(vpath_seq)-1)){
              vtrans[vpath_seq[j], vpath_seq[j+1]] <- vtrans[vpath_seq[j], vpath_seq[j+1]] + 1
              }
          }
          # add pseudo-observations for robustness (only for allowed transitions)
          vtrans[-forbiddenTransitions] <- vtrans[-forbiddenTransitions] + 1
          new_trans <- vtrans / rowSums(vtrans) # normalize by rowSums
          # calculate new initP
          new_initP <- matrix(0, nrow=k, ncol=nseq)
          for (i in 1:nseq) {new_initP[vpath_split[[i]][1], i] <- 1}
          # calculate posteriors (1 for state i at position t if i in viterbi path, else 0)
          posteriors <- matrix(0, nrow=k, ncol=nloci)
          for (i in 1:nloci) {posteriors[vpath[i], i] <- 1}
        }
      }
      checkInterrupt() #check if the user pressed CTRL-C
      if (verbose) cat("Iteration:", iter, "log-likelihood:", new_loglik, "change loglik:", new_loglik-loglik, "\n", sep="\t")
      
      #train models
      new_models <- fitModels(counts, posteriors, models, ucs=ucs, type=nbtype, verbose=verbose, nthreads=nthreads)
      if (iter > 1){
        if (abs(new_loglik - loglik) < tol){
          converged <- TRUE
        } else if (new_loglik < loglik){
          # warning(paste0("decrease in log-likelihood at iteration ", iter))
        }
      }
      #update parameters
      if (!notrain){ # only update parameters in case we want to learn a model
        if (fix_emisP == F){
          models <- new_models
        }
        loglik <- new_loglik
        llhistory[iter] <- loglik
        if (framework=="HMM"){
          # trans_escore <- trans # save previous params for escore calculation
          trans <- new_trans
          initP <- new_initP
        } else {#framework == "MM"
          mix_coeff <- new_mix_coeff
        }
      }
      
      if (converged) break
    }
    if (!converged && verbose) cat("reached the maximum number of iterations\n")
  },
  interrupt=function(i){
    if (verbose) cat("User interrupt detected, stopping main loop and returning current data\n")
  })
  
  # save lliks to lliks_result before overwriting it in the following part of the script ("lLikMat(...)").
  # This is important for the --notrain case because otherwise alpha and lliks don't belong to the same iteration step
  lliks_result <- lliks
  lliks_result[1,1] <- lliks_result[1,1] # dummy-access to the variable in order to evaluate it. without this, it would stay a reference to lliks, which is later changed by c++ without R realizing, leading to the change of lliks_result, too.

  #restore the original sequence splits and compute viterbi path
  if (framework=="HMM"){
    if (!notrain){
      lLikMat(lliks=lliks, counts, models, ucs=ucs, mConst=mConst, nthreads=nthreads, type=fittype)
    }
    if (split4speed) {
      initP <- initP[,s4s$origstarts, drop=F]
      seqlens <- s4s$oldlens
    }
    if (trainMode=="baum-welch") {vit <- viterbi(vscores=vscores, initP, trans, lliks, seqlens, endstate)}
    else if (trainMode=="viterbi") {vit <- res}
    #recompute posterior matrix with the original sequence splits
    if (split4speed){
      res <- forward_backward(posteriors=posteriors, initP, trans, lliks, seqlens, nthreads=nthreads)
      loglik <- res$tot_llik
    }
  }
  #set the histone mark names in the models object
  for (i in seq_along(models)){
    if (nbtype == "lognormal"){ names(models[[i]]$mus) <- rownames(counts); names(models[[i]]$sigmasqs) <- rownames(counts) }
    else{ names(models[[i]]$ps) <- rownames(counts) }
  }
  
  #compute MAP cluster (state) assignments
  #same as: clusters <- apply(posteriors, 2, which.max)
  clusters <- pwhichmax(posteriors, nthreads=nthreads)
  
  # calculate scores for enhancers and promoters (posterior sum of A-states)
  if (trainMode=="baum-welch"){
    states.A <- list(e=which(startsWith(labels, 'E_A')), p=which(startsWith(labels, 'P_A')))
    score <- list(e=apply(res$posteriors[states.A$e,], 2, sum), p=apply(res$posteriors[states.A$p,], 2, sum))
  } else score <- list(e=NULL, p=NULL)

  # calculate escore
  #calculate prior for escore calculation. for that, change the transition matrix at BG <- N1 to zero. 
  #that way, initP_vector %*% trans_for_prior^n (matrix product n times) gives the probabilities for being in particular states after n steps.
  #multiplying this for each state with the probability of leaving the enhancer at the next position and summing over all enhancer states
  #gives the prior for an enhancer of length n.
  # states.e <- which(startsWith(labels, 'E_'))
  # states.n1.e <- which(startsWith(labels, 'E_N1'))
  # states.bg <- which(startsWith(labels, 'bg'))
  # if ((length(states.e) > 0) && (!is.null(res$alpha))){ # only do the enhancer score calculation if there are labeled enhancer states.
  #   if (!notrain){ # in case of a learned model, forward_backward() is rerun to obtain alpha values that match the updated params.
  #     if (verbose) cat("calculate alpha values\n")
  #     res <- forward_backward(posteriors=posteriors, initP, trans, lliks, seqlens, nthreads=nthreads)
  #   }
  #   if (verbose) cat("calculate enhancer scores\n")
  #   initP_for_prior <- rowMeans(initP)
  #   initP_for_prior[-states.e] <- 0
  #   if (sum(initP_for_prior) == 0) initP_for_prior[states.n1.e] <- 1/length(states.n1.e) # assign equal initPs for enhancer states if all zero
  #   initP_for_prior <- initP_for_prior / sum(initP_for_prior)
  #   trans_for_prior <- trans
  #   trans_for_prior[states.bg, states.n1.e] <- 0
  #   trans_for_prior[states.bg,] <- trans_for_prior[states.bg,] / rowSums(trans_for_prior[states.bg,]) # renormalize
  #   p_leave_enhancer <- rowSums(trans_for_prior[states.e, -states.e]) # probability of leaving an enhancer for each enhancer state
  #   maxn <- 30
  #   prior <- sapply(1:maxn, function(x) sum((initP_for_prior %*% innerMatrixProduct_n(trans_for_prior, x))[states.e] * p_leave_enhancer))
  #   prior <- log(prior / sum(prior)) # normalize prior and take log
  #   res2 <- enhancer_score(alpha=res$alpha, initP, trans, lliks_result, seqlens, enhancer_states=(states.e-1),
  #                          escore=escore, prior=prior, nthreads=nthreads)
  #   escore <- exp(res2$escore) # exponentiate escore
  # } else{ escore <- NULL }
  
  #final result
  result <- list(models=models, loglik=loglik, posteriors=posteriors, clusters=clusters,
                 converged=converged, score=score)
  if (!is.null(iter)) {
    result$llhistory <- llhistory[1:iter]
  } else result$llhistory <- NULL

  #if framework==HMM, add init and transition probs and compute viterbi path, and add alpha and lliks (necessary for calculation of enhancer score)
  if (framework=="HMM"){
    result$viterbi <- vit
    result$initP <- initP
    result$trans <- trans
    #result$alpha <- res$alpha
    result$lliks <- lliks_result
  } else {
    #if framework==MM, add the mixture coefficients
    result$mix_coeff <- mix_coeff
  }
  result
}

safeSeq <- function(start, end){
  if (end < start) return(NULL)
  start:end
}

#compute splits for the count matrix such that:
#1. already contain the input splits
#2. allow optimal parallelization with a given number of threads
refineSplits <- function(slens, nthreads){
  slens <- slens[slens > 0]
  stopifnot(nthreads > 0)
  totlen <- sum(slens)
  nthreads <- min(totlen, nthreads)
  
  splitIdx <- cumsum(slens)
  newsplitIdx <- round((1:nthreads)*totlen/nthreads)
  allSplits <- sort(unique(c(splitIdx, newsplitIdx)))
  
  origStarts <- c(1, 1+match(splitIdx[-length(splitIdx)], allSplits))
  newlens <- diff(c(0, allSplits))
  list(newlens=newlens, oldlens=slens, origstarts=origStarts)
}


isProbVector <- function(v, tol=1e-9){
  all(v >= 0) && compare(sum(v), 1, tol)
}

checkModels <- function(models, k, nrow, nbtype){
  if (length(models) != k) stop(paste0("models must be a list of length ", k))
  for (model in models){
    if (length(model$ps) != nrow || !isProbVector(model$ps)) stop("'ps' vector of each model must have the right length and sum up to 1")
    if (!(all(is.finite(c(model$mu, model$ps))) && (unlist(model) >= 0))) stop("non-finite or negative model parameters")
    if (nbtype=="dep" && model$r != models[[1]]$r) warning("models not consistent with the 'dep' setting")
    if (nbtype=="pois" && model$r != Inf) warning("models not consistent with the 'pois' setting")
  }
  
}


#' Fit a negative binomial distribution
#'
#' Maximum Likelihood Estimate for the parameters of a negative binomial distribution
#' generating a specified vector of counts. The MLE for the negative binomial
#' should not be used with a small number of datapoints, it is known to be
#' biased. Internally, this function is using Brent's method to find the
#' optimal dispersion parameter.
#' @param counts a vector of counts. If a list is given, then it is assumed 
#'     to be the result of the function \code{mapToUnique(counts)}
#' @param posteriors a vector specifying a weight for each count. The maximized
#'     function is: \eqn{\sum_{i=1}{L}{posteriors[i]\log(Prob\{counts[i]\}}}. If
#'     not specified, equal weights will be assumed
#' @param old_r an initial value for the size parameter of the negative binomial.
#'     If not specified the methods of moments will be used for an initial guess.
#' @param tol numerical tolerance of the fitting algorithm
#' @param nthreads number of threads. Too many threads might worsen the 
#'     performance
#' @return A list with the parameters of the negative binomial.
#'     \item{mu}{the mu parameter}
#'        \item{r}{the size parameter}
#' @export
fitNB <- function(counts, posteriors=NULL, old_r=NULL, tol=1e-8, verbose=FALSE, nthreads=1){
  #transforming the counts into unique counts
  if (!is.list(counts)){
    ucs <- mapToUnique(counts)
  } else {
    ucs <- counts
  }
  
  if (is.null(posteriors))
    posteriors <- rep(1.0, length(ucs$map))
  
  counts <- ucs$values
  posteriors <- sumAt(posteriors, ucs$map, length(counts), zeroIdx=TRUE)
  
  
  if (is.null(old_r)){
    #the algorithm will figure out a reasonable estimate for r.
    #(match the second moment)
    old_r <- -1
    
  }
  
  fitNB_inner(counts, posteriors, old_r, tol=tol, verbose=verbose, nthreads=nthreads)
  
}

#' Get a steady state of a transition matrix.
#'
#' It should give a similar result as 
#' \code{rep(1/ncol(trans), ncol(trans)) trans^(big number)}
#' except that oscillating behaviours are averaged out.
#' @param trans transition matrix (rows are previous state, columns are next state)
#' @return a vector with a steady state distribution
#'    @export
getSteadyState <- function(trans){
  ttrans <- t(matpowtrans(trans, 2^30))
  as.numeric(ttrans %*% rep(1/ncol(trans), ncol(trans)))
}

#fast exponentiation algorithm,
#correct numerical fuzz by exploiting that 
#the rowSums sum up to 1
matpowtrans <- function(trans, pow){
  if (pow==1){
    trans
  }
  else if (pow %% 2 == 0){
    tmp <- matpowtrans(trans, pow/2)
    tmp <- tmp %*% tmp
    tmp/rowSums(tmp)
  }
  else {
    tmp <- trans %*% matpowtrans(trans, pow-1)
    tmp/rowSums(tmp)
  }
}


compareModels <- function(m1, m2, tol){
  v1 <- c(m1$ps, m1$mu, m1$r)
  v2 <- c(m2$ps, m2$mu, m2$r)
  all(compare(v1, v2, tol))
}

compare <- function(c1, c2, tol){
  if (length(c1)!=length(c2)) stop("cannot compare vectors of different length")
  (abs(c1-c2) <= tol*abs(c1+c2)) | (is.infinite(c1) & is.infinite(c2))
}

generateCol <- function(model){
  rmultinom(1, rnbinom(1, mu=model$mu, size=model$r), prob=model$ps)
}

generateData <- function(n, models, mix_coeff){
  mat <- matrix(0L, ncol=n, nrow=length(models[[1]]$ps))
  for (i in 1:n){
    model <- models[[sample(length(mix_coeff), 1, prob=mix_coeff)]]
    mat[,i] <- generateCol(model)
  }
  mat
}


generateIndependentData <- function(n, models, mix_coeff){
  mat <- matrix(0L, ncol=n, nrow=length(models[[1]]$ps))
  comp <- sample(length(mix_coeff), n, prob=mix_coeff, replace=T)
  for (i in seq_along(mix_coeff)){
    model = models[[i]]
    n = sum(comp==i)
    for (j in seq_along(model$ps)){
      mat[j,comp==i] <- as.integer(rnbinom(n, mu=model$mu*model$ps[j], size=model$r))
    }
  }
  mat
}

exampleData <- function(n=10000, indep=FALSE){
  m1 = list(mu=40, r=0.4, ps=c(1,8,5,8,5,6,5,4,3,2,1))
  m2 = list(mu=20, r=2, ps=c(1,1,1,1,1,3,4,5,6,5,4))
  m1$ps = m1$ps/sum(m1$ps)
  m2$ps = m2$ps/sum(m2$ps)
  p1 = 0.3
  p2 = 0.7
  
  if (indep)
    generateIndependentData(n, list(m1, m2), c(p1,p2))
  else
    generateData(n, list(m1, m2), c(p1,p2))
}


generateHMMData <- function(n, models, trans, initP=getSteadyState(trans)){
  state <- sample(length(models), 1, prob=initP)
  mat <- matrix(0L, ncol=n, nrow=length(models[[1]]$ps))
  mat[,1] <- generateCol(models[[state]])
  for (i in 2:n){
    state <- sample(length(models), 1, prob=trans[state,])
    mat[,i] <- generateCol(models[[state]])
  }
  mat
}

exampleHMMData <- function(n=c(20000, 50000, 30000)){
  m1 = list(mu=40, r=0.4, ps=c(1,8,5,8,5,6,5,4,3,2,1))
  m2 = list(mu=20, r=2, ps=c(1,1,1,1,1,3,4,5,6,5,4))
  m1$ps = m1$ps/sum(m1$ps)
  m2$ps = m2$ps/sum(m2$ps)
  models <- list(m1, m2)
  
  trans = matrix(nrow=2, ncol=2, c(0.2, 0.6, 0.8, 0.4))
  
  
  do.call(cbind, lapply(n, function(currn) {generateHMMData(currn, models, trans)}))
}

innerMatrixProduct_n <- function(M0, n){
  # this function calculates M0^n, i.e. M0 %*% M0 %*% M0 ... n times
  M <- M0
  for (i in 2:n) M <- M %*% M0
  return(M)
}
