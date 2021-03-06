# classtree.R
# Author: Nick Ulle

#' @include tree.R
#' @include cv.R
NULL

#' Grow A Classification Tree
#'
#' This function grows a classification tree from data, following the CART
#' algorithm described in "Classification and Regression Trees". Regression 
#' trees and missing data are not yet supported.
#'
#' @param formula a formula, with a response and covariates.
#' @param data an optional data.frame whose columns are variables named in the
#' formula.
#' @param build_risk a function, to be used for estimating risk when building 
#' the tree. 
#' @param prune_risk a function, to be used for estimating risk when pruning 
#' the tree.
#' @param min_split the minimum number of observations required to make a split.
#' @param min_bucket the minimum number of observations required in each leaf.
#' @param folds the number of folds to be used in cross-validation of the
#' cost-complexity parameter. If this is not positive, cross-validation will be
#' skipped.
#' @param prior a numeric vector of prior probabilities for each class. This
#' parameter is ignored when doing regression.
#' @return a reference class ClassTree, representing the classification tree.
#'
#' @examples
#' # Build a classification tree for Fisher's iris data using defaults.
#' makeTree(Species ~ ., iris)
#'
#' # Build a classification tree for the insect spray data using
#' # misclassification rate instead of Gini impurity, and require at least 25
#' # observations in every split node.
#' makeTree(spray ~ count, InsectSprays, build_risk = riskError, 
#'          min_split = 25L)
#'
#' # Build a classifcation tree for the included housing data set, which is
#' # somewhat 'large'. This code will take a long time to run.
#' \dontrun{data(housing)}
#' \dontrun{makeTree(city ~ ., housing)}
#' \dontrun{library(rpart)}
#' \dontrun{rpart(city ~ ., housing, control = list(xval = 10))}
#' @export
makeTree <- function(formula, data, 
                     build_risk = riskGini, prune_risk = riskError, 
                     min_split = 20L, min_bucket = round(min_split / 3),
                     folds = 10L, prior) {
    # Parse formulas into a data frame with response and covariate columns.
    call_signature <- match.call(expand.dots = FALSE)
    m <- match(c('formula', 'data'), names(call_signature))
    call_signature <- call_signature[c(1L, m)]
    call_signature[[1L]] <- as.name('model.frame')
    data <- eval(call_signature, parent.frame())

    # Set up risk functions as a list.
    N <- table(data[[1]])
    if(missing(prior)) prior <- N / sum(N)
    risk <- list(build_risk = function(.) build_risk(., N, prior, TRUE),
                 prune_risk = function(.) {
                     . <- list(., .[0])
                     prune_risk(., N, prior, FALSE)[[1]]
                 })

    tree <- makeSubtree(data, risk, min_split, min_bucket)
    tree$finalizeCollapse()

    if (folds > 0L) {
        # Define a training function to use in cross-validation.
        trainTree <- function(data) {
            tree <- makeSubtree(data, risk, min_split, min_bucket)
            tree$finalizeCollapse()
            return(tree)
        }
        
        # Also define a validation function. Use proportion wrongly predicted
        # as validation score.
        validateTree <- function(tuning, tree, test_set) {
            pred <- tree$predict(test_set, tuning)
            sum(test_set[[1L]] != pred) / nrow(test_set)
        }
    
        # Always include 0 as a possible setting for the tuning parameter.
        tuning <- c(0, sort(tree$getTuning(), decreasing = FALSE))
        tuning <- unique(tuning)
        cv <- crossValidate(data, trainTree, validateTree, tuning, folds)
        best <- which.min(cv$estimate)

        # Use the "one standard error" rule: get the smallest tuning parameter
        # whose estimated prediction error is within one standard error of the
        # (larger) best tuning parameter.
        cv <- cv[cv$estimate < cv$estimate[[best]] + cv$error[[best]], ]
        tuning <- cv$parameter[[1L]]
    
        # Prune the tree using the cv'd tuning parameter.
        tree$prune(tuning)
    }

    return(tree)
}

#' Grow A Random Forest
#'
#' This function grows a forest of classification trees from data.
#'
#' @param formula a formula, with a response and covariates.
#' @param data an optional data.frame whose columns are variables named in the
#' formula.
#' @param risk a function, to be used for estimating risk when growing the tree.
#' @param num_trees the number of trees to grow.
#' @param num_covariates the number of covariates to select (randomly) when
#' determining each split.
#' @param min_split the minimum number of observations required to make a split.
#' @param min_bucket the minimum number of observations required in each leaf.
#' @param prior a numeric vector of prior probabilities for each class. This
#' parameter is ignored when doing regression.
#' @return An S3 class ClassForest, representing the forest of classification 
#' trees.
#' @examples
#'
#' randomForest(Species ~ ., iris, riskGini, 10, 2)
#'
#' @export
randomForest <- function(formula, data, risk = riskGini, num_trees, 
                         num_covariates, min_split = 20L, 
                         min_bucket = round(min_split / 3), prior) {
    # TODO: clean up & unify tree-growing interfaces.
    call_signature <- match.call(expand.dots = FALSE)
    m <- match(c('formula', 'data'), names(call_signature))
    call_signature <- call_signature[c(1L, m)]
    call_signature[[1L]] <- as.name('model.frame')
    data <- eval(call_signature, parent.frame())

    # Set up risk functions as a list. Since random forests are not pruned,
    # a dummy function is used for computing the prune risk.
    N <- table(data[[1]])
    if(missing(prior)) prior <- N / sum(N)
    risk2 <- list(build_risk = function(.) risk(., N, prior, TRUE),
                  prune_risk = function(.) 0)

    # Get bootstrap samples.
    n <- nrow(data)
    sample_indices <- replicate(num_trees, sample.int(n, n, TRUE))

    # Run makeSubtree on each bootstrapped sample.
    forest <- apply(sample_indices, 2L,
                    function(i_) {
                        training_set <- data[i_, ]
                        #test_set <- [-i_, ]
                        makeSubtree(training_set, risk2, min_split, min_bucket, 
                                    num_covariates = num_covariates)
                    })
    structure(forest, class = 'ClassForest')
}

#' Print Method For Random Forests
#'
#' @param x a ClassForest object, which will be printed to the console.
#' @param ... further arguments passed to or from other methods.
#' @method print ClassForest
#' @S3method print ClassForest
print.ClassForest <- function(x, ...) {
    # TODO: add OOB error estimate.
    cat(paste0('Random forest with ', length(x), ' trees.\n'))
}

#' Predict Method For Random Forests
#'
#' @param object a ClassForest object, which will be used to make the
#' prediction.
#' @param data a data.frame of new data for which to make predictions.
#' @param ... reserved for future use.
#' @return A vector of predictions, one for each row of \code{data}.
#' @method predict ClassForest
#' @S3method predict ClassForest
predict.ClassForest <- function(object, data, ...) {
    pred <- lapply(object, function(tree_) tree_$predict(data, -Inf))
    pred <- Reduce(cbind, pred)
    apply(pred, 1L, function(pred_) names(which.max(table(pred_))))
}

# Makes a subtree given the data.
makeSubtree <- function(data, risk, min_split, min_bucket, tree,
                        num_covariates = Inf) {
    details <- splitDetails(data[1L])
    if (missing(tree)) tree <- ClassTree(length(details$n))
    tree$decision <- details$decision
    tree$n <- details$n

    # Decide if we should split, and do splitting stuff.
    # In any iteration we need to check that the parent is big enough to split,
    # and that the children are big enough to keep the split.
    if(sum(tree$n) >= min_split) {
        # Find the best split and then split the data.
        split <- bestSplit(data[-1L], data[1L], risk$build_risk, num_covariates)

        split_data <- factor(data[[split$variable]] %<=% split$point, 
                             levels = c(TRUE, FALSE))
        split_data <- split(data, split_data)

        # Count how many observations fall on each side of the split.
        split_n <- vapply(split_data, nrow, 0L)
        
        if (all(split_n >= min_bucket)) {
            # Keep this split -- make this node a branch.
            tree$addSplit(split$variable, split$point)

            tree$goLeft()
            makeSubtree(split_data[[1L]], risk, min_split, min_bucket, tree)
            tree$goUp()

            tree$goRight()
            makeSubtree(split_data[[2L]], risk, min_split, min_bucket, tree)
            tree$goUp()
        }
    }

    # Update risks for future cost-complexity pruning.
    #tree$risk <- risk$prune_risk(data[1L]) * sum(tree$n)
    tree$risk <- risk$prune_risk(data[[1]])
    tree$updateCollapse()
    return(tree)
}

# Finds best split among all covariates.
bestSplit <- function(x, y, risk, num_covariates = Inf) {
    # Randomly choose covariates in case of random forests.
    if (num_covariates < ncol(x)) x <- x[sample.int(ncol(x), num_covariates)]

    # Determine which covariates are ordinal and which are nominal.
    nominal <- vapply(x, is.factor, NA)
    x_nom <- x[nominal]
    x_ord <- x[!nominal]

    if (ncol(x_nom) > 0L) {
        # For each nominal covariate, make a list of all unique splits.
        x_nom_q <- lapply(x_nom,
                          function(x_) {
                              x_ <- levels(x_)
                              q <- matrix(c(TRUE, FALSE), 2L, length(x_) - 1)
                              q <- as.matrix(expand.grid(as.data.frame(q)))
                              q <- cbind(TRUE, q[-1L, ])
                              dimnames(q) <- NULL
                              q <- apply(q, 1L, function(q_) factor(x_[q_], x_))
                              as.list(q)
                          })
    } else x_nom_q <- NULL

    if (ncol(x_ord) > 0L) {
        # For each ordinal covariate, make a sorted vector of all unique 
        # midpoints.
        x_ord_q <- lapply(x_ord,
                          function(x_) {
                              x_ <- sort(unique(x_))
                              x_ <- (head(x_, -1L) + tail(x_, -1L)) / 2
                          })
    } else x_ord_q <- NULL

    # Now combine everything and find the best split.
    x <- c(x_nom, x_ord)
    x_q <- c(x_nom_q, x_ord_q)

    splits <- mapply(bestSplitWithin, x_q, x, MoreArgs = list(y, risk))
    best <- which.min(splits[1, ])

    list(variable = colnames(splits)[[best]], point = splits[[2L, best]])
}

# Finds best split within one covariate.
bestSplitWithin <- function(x_q, x, y, risk) {
    splits <- vapply(x_q,
                     function(x_) { 
                         y_split <- factor(x %<=% x_, c(TRUE, FALSE))
                         y_split <- split(y, y_split)
                         risk(y_split)
                        }, NA_real_)
    best <- which.min(splits)
    list(splits[[best]] / nrow(y), x_q[[best]])
}

#' Left Branch Operator
#'
#' This is a binary operator which returns a logical vector indicating whether
#' \code{x} gets sent to the left branch under the split defined by \code{y}.
#' In particular, if \code{y} is numeric, this tests whether the elements of
#' \code{x} are less than or equal to \code{y}, and if \code{y} is a factor,
#' this tests whether the elements of \code{x} are in \code{y}.
#'
#' @param x a vector, the values to be tested.
#' @param y a numeric value or a factor, which defines the split.
#' @return A logical vector of the same length as \code{x}.
#' @rdname LeftBranch
#' @export
'%<=%' <- function(x, y) UseMethod('%<=%', y)

#' @rdname LeftBranch
#' @method \%<=\% default
#' @S3method %<=% default
'%<=%.default' <- function(x, y) as.numeric(x) <= as.numeric(y)

#' @rdname LeftBranch
#' @method \%<=\% factor
#' @S3method %<=% factor
'%<=%.factor' <- function(x, y) x %in% y

#' @rdname LeftBranch
#' @method \%<=\% list
#' @S3method %<=% list
'%<=%.list' <- function(x, y) mapply('%<=%', x, y)

#' Retrieve Split Details
#'
#' \code{splitDetails} retrieves the number of elements and the decision
#' for a split.
#' 
#' @param y a factor, containing the true classes of the split observations.
#' @return a list, containing the name of the majority class and the number
#' of observations in each class.
splitDetails <- function(y) {
    n <- c(table(y))
    decision <- names(which.max(n))
    list(decision = decision, n = n)
}

getNodeP <- function(y, N, prior) {
    N <- as.numeric(N)
    prior <- as.numeric(prior)

    p <- cbind(left = table(y[[1L]]), right = table(y[[2L]]))
    p <- t(prior * p / N)
    
    list(joint = p, conditional = p / rowSums(p))
}

#' Risk Functions
#'
#' These functions compute the risk of a split. For classification, possible
#' metrics are error, gini coefficient, information entropy, and twoing. The
#' former three are also available for computing the risk of a node by setting
#' the \code{avg} parameter to FALSE. For regression, possible metrics are
#' sum of squared error (SSE) and sum of absolute error (SAE); these functions
#' ignore all parameters except \code{y}.
#'
#' Custom risk functions can also be written by the user, provided they have
#' the same behavior and signature described in this file.
#'
#' @param y a factor (for classification) or a numeric vector (for regression).
#' @param N a numeric vector of overall sample counts for each class.
#' @param prior a numeric vector of prior probabilities for each class.
#' @param avg a logical indicating whether to take the weighted average of
#' the risk for each side.
#' @return a numeric cost.
#' @rdname Risk
#' @export
riskError <- function(y, N, prior, avg) {
    p <- getNodeP(y, N, prior)
    error <- 1 - apply(p$cond, 1L, max)

    risk <- error * rowSums(p$joint)
    # Take weighted average of each side, if requested.
    if (avg) risk <- sum(risk) / sum(p$joint)
    return(risk)
}

#' @rdname Risk
#' @export
riskGini <- function(y, N, prior, avg) {
    p <- getNodeP(y, N, prior)
    gini <- rowSums(p$cond - p$cond^2)

    risk <- gini * rowSums(p$joint)
    # Take weighted average of each side, if requested.
    if (avg) risk <- sum(risk) / sum(p$joint)
    return(risk)
}

#' @rdname Risk
#' @export
riskEntropy <- function(y, N, prior, avg) {
    p <- getNodeP(y, N, prior)
    entropy <- rowSums(ifelse(p$c == 0, 0, -p$c * log(p$c)))

    risk <- entropy * rowSums(p$joint)
    # Take weighted average of each side, if requested.
    if (avg) risk <- sum(risk) / sum(p$joint)
    return(risk)
}

#' @rdname Risk
#' @export
riskTwoing <- function(y, N, prior, avg) {
    p <- getNodeP(y, N, prior)
    twoing <- sum(abs(p$j[1L, ] - p$j[2L, ]))^2
    risk <- -prod(rowSums(p$j) / sum(p$j)) * twoing / 4
    return(risk)
}

#' @rdname Risk
#' @export
riskSSE <- function(y, N, prior, avg) {
    sse <- vapply(y, function(y_) norm(mean(y_) - y_, '2')^2, 0)
    sum(sse)
}

#' @rdname Risk
#' @export
riskSAE <- function(y, N, prior, avg) {
    sae <- vapply(y, function(y_) sum(abs(mean(y_) - y_)), 0)
    sum(sae)
}

ClassTree = setRefClass('ClassTree', contains = c('Tree'),
    fields = list(
        variable_ = 'character',
        variable = function(x) {
            if (missing(x)) variable_[[cursor]]
            else variable_[[cursor]] <<- x
        },
        point = 'list',
        decision_ = 'character',
        decision = function(x) {
            if (missing(x)) decision_[[cursor]]
            else decision_[[cursor]] <<- x
        },
        risk_ = 'numeric',
        risk = function(x) {
            if (missing(x)) risk_[[cursor]]
            else risk_[[cursor]] <<- x
        },
        leaf_risk_ = 'numeric',
        leaf_risk = function(x) {
            if (missing(x)) leaf_risk_[[cursor]]
            else leaf_risk_[[cursor]] <<- x
        },
        leaf_count_ = 'integer',
        leaf_count = function(x) {
            if (missing(x)) leaf_count_[[cursor]]
            else leaf_count_[[cursor]] <<- x
        },
        collapse_ = 'numeric',
        collapse = function(x) {
            if (missing(x)) collapse_[[cursor]]
            else collapse_[[cursor]] <<- x
        },
        n_ = 'matrix',
        n = function(x) {
            if (missing(x)) n_[cursor, ]
            else n_[cursor, ] <<- x
        }
    ),
    methods = list(
        initialize = function(classes = 0L, ...) {
            callSuper(n_ = matrix(NA_integer_, 0L, classes), ...)
            # Set values.
            variable <<- NA_character_
            point[[1L]] <<- NA
        },

        # ----- Memory Allocation -----
        increaseReserve = function() {
            callSuper()
            new_length <- length(variable_) + mem_reserve
            length(variable_) <<- new_length
            length(point) <<- new_length
            length(decision_) <<- new_length
            length(risk_) <<- new_length
            length(leaf_risk_) <<- new_length
            length(leaf_count_) <<- new_length
            length(collapse_) <<- new_length
            n_ <<- rbind(n_, matrix(NA_integer_, mem_reserve, dim(n_)[[2L]]))
        },

        # ----- Node Creation -----
        addSplit = function(variable, point) {
            addLeft()
            addRight()
            l_id <- frame[[cursor, 1L]]
            r_id <- frame[[cursor, 2L]]
            variable_[c(l_id, r_id)] <<- variable
            point[[r_id]] <<- point[[l_id]] <<- point
        },

        # ----- Node Deletion -----
        removeNode = function() {
            callSuper()
            variable_ <<- variable_[-cursor]
            point <<- point[-cursor]
            decision_ <<- decision_[-cursor]
            risk_ <<- risk_[-cursor]
            leaf_risk_ <<- leaf_risk_[-cursor]
            leaf_count_ <<- leaf_count_[-cursor]
            collapse_ <<- collapse_[-cursor]
            n_ <<- n_[-cursor, ]
        },

        # ----- Display -----
        showSubtree = function(id, level = 0L, node = 1L) {
            str_variable <- variable_[[id]]
            if (is.na(str_variable)) str_variable <- '<root>'

            str_point <- point[[id]]
            str_point <- if (class(str_point) == 'factor') {
                if ((node %% 2L) == 0L)
                    paste0('in {', paste0(str_point, collapse = ', '), '}')
                else
                    paste0('not in {', paste0(str_point, collapse = ', '), '}')
            } else if (class(str_point) == 'logical') {
                str_point
            } else {
                if ((node %% 2L) == 0L) paste0('<= ', str_point)
                else paste0('> ', str_point)
            }

            str_n <- paste0('(', paste0(n_[id, ], collapse = ' '), ')')

            str <- paste(str_variable, str_point, decision_[[id]], str_n)
            cat(rep.int('  ', level), node, ') ', str, '\n', sep = '')

            l_id <- frame[[id, 1L]]
            r_id <- frame[[id, 2L]]
            if (!is.na(l_id)) showSubtree(l_id, level + 1L, 2L * node)
            if (!is.na(r_id)) showSubtree(r_id, level + 1L, 2L * node + 1L)
        },

        # ----- Special Methods -----
        getTuning = function() {
            collapse_[is.finite(collapse_)]
        },

        updateCollapse = function() {
            ids <- frame[cursor, 1L:2L]

            if (isLeaf()) {
                # Leaf risk of a leaf is just its risk.
                leaf_risk <<- risk
                leaf_count <<- 1L
                collapse <<- Inf
            } else {
                # Leaf risk of a branch is the sum of its child risks.
                leaf_risk <<- sum(leaf_risk_[ids])
                leaf_count <<- sum(leaf_count_[ids])
                collapse <<- (risk - leaf_risk) / (leaf_count - 1L)
            }
        },

        # The final sequence of collapse points for consideration in CV comes
        # from collapsing the weakest link, recalculating the collapse points,
        # and repeating. This function performs that procedure.
        finalizeCollapse = function() {
            # NOTE: Multiple best collapse points are not handled
            # simultaneously, but rather by consecutive iterations. This is 
            # also how the algorithm outlined by Breiman operates.

            final_collapse <- rep(Inf, next_id - 1L)
            final_leaf_risk <- leaf_risk_
            final_leaf_count <- leaf_count_

            # Move to minimum collapse node, change is risk as though it was
            # pruned, and then update the tree. Repeat until reaching the root.
            cursor <<- which.min(collapse_)
            while (!isRoot()) {
                # Store this node's collapse value.
                final_collapse[[cursor]] <- collapse

                # Make this node's risk look like a leaf.
                leaf_risk <<- risk
                leaf_count <<- 1L
                collapse <<- Inf

                # Update ancestors.
                while(!isRoot()) {
                    goUp()
                    updateCollapse()
                }
                # Get new best collapse point.
                cursor <<- which.min(collapse_)
            }

            final_collapse[[cursor]] <- collapse
            # Collapse points should be non-negative.
            final_collapse <- pmax.int(final_collapse, 0L)
            collapse_[seq_along(final_collapse)] <<- final_collapse
            # TODO: possibly redesign updateCollapse() so that storing
            # leaf_risk_ and leaf_count_ is not necessary.
            leaf_risk_ <<- final_leaf_risk
            leaf_count_ <<- final_leaf_count
        },

        prune = function(cutoff) {
            # Walk down the tree, pruning any branch  whose collapse value 
            # doesn't exceed cutoff.
            if (!isLeaf()) {
                if (collapse <= cutoff) {
                    # This branch gets pruned, so make this node a leaf.
                    removeLeft()
                    removeRight()
                } else {
                    # This branch does not get pruned, so descend.
                    goLeft()
                    prune(cutoff)
                    goUp()

                    goRight()
                    prune(cutoff)
                    goUp()
                }
                # TODO: the leaf risks and leaf counts should be updated here.
                # This is a minor point, and only need to be fixed before
                # release.
            }
        },

        predict = function(data, cutoff = 0L) {
            # TODO: this function could be more efficient.
            ids <- rep.int(1L, nrow(data))
            prev_ids <- 0L

            while (any(ids != prev_ids)) {
                prev_ids <- ids

                # Get left child of previous node for every row.
                ids <- frame[prev_ids, 1L]
                variables <- cbind(seq_len(nrow(data)), 
                                   match(variable_[ids], colnames(data))
                                   )

                # Check split condition in left child for every row.
                ids <- ifelse(data[variables] %<=% point[ids],
                              ids, 
                              frame[prev_ids, 2L]
                              )

                # Don't descend if previous node had no children.
                ids <- ifelse(is.na(ids), prev_ids, ids)
                ids <- ifelse(collapse_[prev_ids] <= cutoff, prev_ids, ids)
            }
            return(decision_[ids])
        }
    ) # end methods
)

