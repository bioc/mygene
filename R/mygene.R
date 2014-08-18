library(GenomicFeatures)
library(IRanges)
library(httr)
library(jsonlite)
library(sqldf)

version <- '0.3'
MyGene <- setClass("MyGene",
    slots=list(base.url="character", delay="numeric", step="numeric", version="character", verbose="logical", debug="logical"),
    prototype=list(base.url="http://mygene.info/v2", delay=1, step=1000, version=version, verbose=TRUE, debug=FALSE))

validMyGeneObject <- function(object) {
    errors <- character(0)
    for (sn in c("base.url", "delay", "step")) {
        if (length(slot(object, sn)) != 1)
            errors <- c(errors, sprintf("Slot %s must have length 1", sn))
    }
    if (length(errors) > 0)
        errors
    else
        TRUE
}

setValidity("MyGene", validMyGeneObject)

.return.as<-function(gene_obj, return.as = c("DataFrame", "records", "text")) {
    return.as <- match.arg(return.as)
    ## Get the records, then call jsonlite:::simplify to convert to a
    ## data.frame
    if (return.as == "DataFrame") {
      gene_obj <- .return.as(gene_obj, "records")
      outdf <-jsonlite:::simplify(gene_obj)
      # This expands out any inner columns that may themselves be data frames.
      outdf <- .unnest.df(outdf)
      return(.df2DF(outdf))
    }
    else if (return.as == "text") {
        return(gene_obj)
    }
    else {
        return(fromJSON(gene_obj, simplifyDataFrame=FALSE))}
}

setGeneric(".request.get", signature=c("mygene"),
            function(mygene, path, params=list()) standardGeneric(".request.get"))

setMethod(".request.get", c(mygene="MyGene"),
            function(mygene, path, params=list()){

    url <- paste(mygene@base.url, path, sep="")
    headers<-c('User-Agent' = sprintf('R-httr_mygene.R/httr.%s', version))
    if (exists('params')){
        if (mygene@debug){
            res <- GET(url, query=params, verbose())
        }
        else{
            res <- GET(url, query=params, config=add_headers(headers))
            }
        }
    if (res$status_code != 200)
        stop("Request returned unexpected status code:\n",
             paste(capture.output(print(res)), collapse="\n"))
    httr::content(res, "text")

})

setGeneric(".request.post", signature=c("mygene"),
            function(mygene, path, params=list()) standardGeneric(".request.post"))

setMethod(".request.post", c(mygene="MyGene"),
            function(mygene, path, params=list()) {

    url <- paste(mygene@base.url, path, sep="")
    headers<-c('Content-Type'= 'application/x-www-form-urlencoded',
            'User-Agent' = sprintf('R-httr_mygene.R/httr.%s', version))
    if (exists('params')){
        if (mygene@debug){
            res <- POST(url, body=params, config=list(add_headers(headers)), verbose())
        }
        else{
            res <- POST(url, body=params, config=list(add_headers(headers)))
            }
        }
    if (res$status_code != 200)
        stop("Request returned unexpected status code:\n",
             paste(capture.output(print(res)), collapse="\n"))
    httr::content(res, "text")
})


.repeated.query <- function(mygene, path, vecparams, params=list(), return.as) {

    verbose <- mygene@verbose
    vecparams.split <- .transpose.nested.list(lapply(vecparams, .splitBySize, maxsize=mygene@step))
    if (length(vecparams.split) <= 1){
        verbose <- FALSE
    }
    vecparams.splitcollapse <- lapply(vecparams.split, lapply, .collapse)
    n <- length(vecparams.splitcollapse)
    reslist <- character(n)
    i <- 1
    repeat {
        if (verbose) {
          message("Querying chunk ", i)
        }
        params.i <- c(params, vecparams.splitcollapse[[i]])
        reslist[[i]] <- .request.post(mygene=mygene, path, params=params.i)
        ## This avoids an extra sleep after the last fragment
        if (i == n){
            break()
        }
        Sys.sleep(mygene@delay)
        i <- i+1
    }
    # This gets the text that would have been returned if we could submit all genes in a single query.
    restext <- .json.batch.collapse(reslist)
    return(restext)
}

setMethod("metadata", c(x="MyGene"), function(x, ...) {
    .return.as(.request.get(x, "/metadata"), "records")
})

setGeneric("getGene", signature=c("mygene"),
            function(geneid, fields = c("symbol","name","taxid","entrezgene"),
            ..., return.as=c("records", "text"), mygene) standardGeneric("getGene"))

setMethod("getGene", c(mygene="MyGene"),
            function(geneid, fields = c("symbol","name","taxid","entrezgene"),
            ..., return.as=c("records", "text"), mygene) {

    return.as <- match.arg(return.as)
    params <- list(...)
    params$fields <- .collapse(fields)
    res <- .request.get(mygene, paste("/gene/", geneid, sep=""), params)
    .return.as(res, return.as=return.as)
})

## If nothing is passed for the mygene argument, just construct a
## default MyGene object and use it.
setMethod("getGene", c(mygene="missing"),
            function(geneid, fields = c("symbol","name","taxid","entrezgene"),
            ..., return.as=c("records", "text"), mygene) {

    mygene <- MyGene()
    getGene(geneid, fields, ..., return.as=return.as, mygene=mygene)
})

setGeneric("getGenes", signature=c("mygene"),
            function(geneids, fields = c("symbol","name","taxid","entrezgene"),
            ..., return.as = c("DataFrame", "records", "text"), mygene) standardGeneric("getGenes"))

setMethod("getGenes", c(mygene="MyGene"),
            function(geneids, fields = c("symbol","name","taxid","entrezgene"),
            ..., return.as = c("DataFrame", "records", "text"), mygene) {

    return.as <- match.arg(return.as)
    if (exists('fields')) {
        params <- list(...)
        params[['fields']] <- .collapse(fields)
        params <- lapply(params, function(x) {str(x);.collapse(x)})
    }
    vecparams <- list(ids=.uncollapse(geneids))
    res <- .repeated.query(mygene, '/gene/', vecparams=vecparams, params=params)
    .return.as(res, return.as=return.as)

})

setMethod("getGenes", c(mygene="missing"),
            function(geneids, fields = c("symbol","name","taxid","entrezgene"),
            ..., return.as = c("DataFrame", "records", "text"), mygene) {

    mygene <- MyGene()
    getGenes(geneids, fields, ..., return.as=return.as, mygene=mygene)
})

setGeneric("query", signature=c("mygene"),
            function(q, ..., return.as=c("DataFrame", "records", "text"), mygene) standardGeneric("query"))

setMethod("query", c(mygene="MyGene"),
            function(q, ..., return.as=c("DataFrame", "records", "text"), mygene) {

    return.as <- match.arg(return.as)
    params <- list(...)
    params[['q']] <- q
    res <- .request.get(mygene, paste("/query/", sep=""), params)
    if (return.as == "DataFrame"){
        return(fromJSON(res))
    }
    else if (return.as == "text"){
        return(.return.as(res, "text"))
    }
    else if (return.as == "records"){
        return(.return.as(res, "records"))
    }

})

setMethod("query", c(mygene="missing"),
            function(q, ..., return.as=c("DataFrame", "records", "text"), mygene) {

    mygene <- MyGene()
    query(q, ..., return.as=return.as, mygene=mygene)
})

setGeneric("queryMany", signature=c("mygene"),
            function(qterms, scopes=NULL, ..., return.as=c("DataFrame", 
            "records", "text"), mygene) standardGeneric("queryMany"))

setMethod("queryMany", c(mygene="MyGene"),
            function(qterms, scopes=NULL, ..., return.as=c("DataFrame", 
            "records", "text"), mygene){ 
    
    return.as <- match.arg(return.as)
    params <- list(...)        
    vecparams<-list(q=.uncollapse(qterms))
    if (exists('scopes')){
        params<-lapply(params, .collapse)
        params[['scopes']] <- .collapse(scopes)
         returnall <- .pop(params,'returnall', FALSE)
         params['returnall'] <-NULL
        verbose <- mygene@verbose
        
        if (length(qterms) == 0) {
          return(query(qterms, ...))
        } 
        
        li_query <-c()
        li_missing<-c()
        out <- .repeated.query(mygene, '/query/', vecparams=vecparams, params=params)
        out.li <- .return.as(out, "records")
        
        for (hits in out.li){
          if (is.null(hits$notfound)){
            li_query<-c(li_query, hits[['query']])
          }
          else if (hits$notfound) {
            li_missing<-c(li_missing, hits[['query']])
          }
        }        
        #check duplication hits
        li_cnt<-as.list(table(li_query))
        li_dup<-li_cnt[li_cnt > 1]
        
        if (verbose){
            cat("Finished\n")
            if (length('li_dup')>0){
                sprintf('%f input query terms found dup hits:   %s', length(li_dup), li_dup)
            }
            if (length('li_missing')>0){
                sprintf('%f input query terms found dup hits:   %s', length(li_missing), li_missing)
                }
            }
        out <- .return.as(out, return.as=return.as)
        if (returnall){
            return(list('out'= out, 'dup'=li_dup, 'missing'=li_missing))
        }
        else {
            if (verbose & ((length(li_dup)>=1) | (length(li_missing)>=1))){
                cat('Pass returnall=TRUE to return lists of duplicate or missing query terms.\n')
                }
            return(out)    
        }
    }
})

setMethod("queryMany", c(mygene="missing"),
            function(qterms, scopes=NULL, ...,
            return.as=c("DataFrame", "records", "text"), mygene){

    mygene<-MyGene()
    # Should use callGeneric here except that callGeneric gets the variable scoping wrong for the "..." argument
    queryMany(qterms, scopes, ..., return.as=return.as, mygene=mygene)
})

# tx.id is a foreign key. matches tx.id from transcripts.
index.tx.id<-function(transcripts, splicings){#, genes){
  transcripts$tx_id <- as.integer(seq_len(nrow(transcripts)))  
  new.splicings<-sqldf("SELECT tx_id, 
                       exon_rank, 
                       exon_start, 
                       exon_end  
                       FROM transcripts 
                       NATURAL JOIN splicings")
  genes<-sqldf("SELECT tx_id, 
               gene_id
               FROM transcripts")
  transcripts$num_exons<-NULL
  transcripts$cdsstart<-NULL
  transcripts$cdsend<-NULL
  transcripts$gene_id<-NULL
  makeTranscriptDb(transcripts, new.splicings, genes) 
}

merge.df<-function(df.list){
  transcript.list<-lapply(df.list, `[[`, "transcripts")
  splicing.list<-lapply(df.list, `[[`, "splicings")
  transcripts <- do.call(rbind, transcript.list) 
  splicings <- do.call(rbind, splicing.list)
  index.tx.id(transcripts, splicings)
}

extract.tables.for.gene <- function(query) {
  query.exons <- query$exons
  txdf <- data.frame(tx_name=names(query.exons), 
                     num_exons=sapply(query.exons, function(x) nrow(x$exons)),
                     sapply(c("chr", "strand", "txstart", "cdsstart", "cdsend", "txend"), 
                            function(i) sapply(query.exons, `[[`, i), simplify=FALSE),
                     gene_id=query$`_id`)
  txdf$strand <- factor(ifelse(txdf$strand == 1, "+", "-"), levels=c("+", "-", "*"))
  txdf <- rename(txdf, c(txstart="tx_start", txend="tx_end",
                         chr="tx_chrom", strand="tx_strand"))
  splicings <- data.frame(
    do.call(rbind,
            lapply(row.names(txdf), function(txname) {
              start.end.table <- data.frame(query.exons[[txname]]$exons)
              names(start.end.table)[1:2] <- c("exon_start", "exon_end")
              start.end.table <- start.end.table[order(start.end.table$exon_start, start.end.table$exon_end),]
              eranks <- seq(nrow(start.end.table))
              if (txdf[txname,]$tx_strand == "-")
                eranks <- rev(eranks)
              data.frame(start.end.table, 
                         exon_rank=eranks,
                         tx_name=txname)
            })))
  df.list<-list(transcripts=txdf, splicings=splicings)
  df.list
}

makeTranscriptDbFromMyGene <- function(gene.list, scopes, species){
  if (length(gene.list) == 1) {
    res<-query(gene.list,
               scopes=scopes,
               fields="exons",
               species=species, 
               size=1,
               return.as="records")$hits
  } else {  
    res<-queryMany(gene.list,
                   scopes=scopes,
                   fields="exons",
                   species=species,
                   return.as="records")
  }
  merge.df(lapply(res, function(i) extract.tables.for.gene(i)))
  
}