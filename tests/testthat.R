library(testthat)
library(ehmm)

#set seed so that errors are reproducible
set.seed(13)
filt <- NULL
#we don't run the CLI tests on Windows
if (.Platform$OS.type != "unix") filt <- "^[A-Za-z]"
test_check("ehmm", filter=filt, reporter="summary")
