% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/getcounts.R
\name{refineRegions}
\alias{refineRegions}
\title{Refine regions}
\usage{
refineRegions(regions, binsize)
}
\arguments{
\item{regions}{GRanges object containing the genomic regions of interest.}

\item{binsize}{The size of each bin in basepairs.}
}
\value{
A GRanges object with the refined regions.
}
\description{
Refine a GRanges object to make sure that it is compatible with a 
binning scheme of a given binsize. There is more than one way of doing it.
In the way it is done here, the start coordinates and the end coordinates
of the provided regions will become respectively the next number of the form 
\code{binsize*k + 1} and the previous number of the form \code{binsize*k},
so that the refined regions will always be contained in the original ones.
}
