ok, so lets recap what our performance status quo is:

- we have added some performance logging classes, so if you filter for perf.backend you get a good overview of what happens
- currently, we cannot trace solid simply because solidcommunity.net is down
- with gdrive mirror, it does not seem to make a difference if we use shard or not (!) - initial download now was appr. 4,5 sec both
- without mirror, shard should be faster (did not yet test it though), but it is 25 seconds, which is way too slow

What we might want  to work on:

### gdrive mirror
Speed seems okayish, but I think it is still slower than it should. Possible areas for improvement:
- gdrive-index.ttl is poorly implemented - we do three times get and an extra list. we must include this in the mirror to get rid of extra list
- during finalize we upload all files after querying them again.
  - should we really re-query? Maybe better list if really needed?
  - is it really correct that all files were changed and had to be re-uploaded??? I guess due to the installation tracking

**General Concerns**
This approach is really contrary to "fetch what you need" because we do not know initially what we need. One should view this as an experiment for determinig the best possible performance - but this probably is not a solution we will want to ship to users :-/

Or we have to think about what enabling this means in the long term - can we take learnings and apply them without storing in a local filesystem "cache"?

### gdrive (normal, dataset)
Performance of non-mirror currently is totally unacceptable. Even regular re-sync without any changes (dataset mode) takes nearly 9 seconds every time! And the initial download took 25 seconds!

But, looking at our request logs I do believe that there must be a lot of potential for improvements.

### conceptual problems

- we store the installations (e.g. the clients) in the shards - this causes us to write every shard file back on initial sync, slowing down our highly optimized gdrive mirrored sync by appr. 1.5 sec - without it we should be slightly below 3 seconds 

----

## Next Steps (ideas)

- Investigate Bug: Using dataset for both local and mirrored gdrive, I seem to sometimes loose notes and/or categories in gdrive? Could this be caused by mirror?
- Revisit concept to try to get rid of the reader references in the index documents - what would happen if we did not have them? Can we maybe move them somewhere else to reduce the amount of files touched during initial sync? What about reverting this and keeping track of the indices in the installation document instead?
- reality check: port chat essence to sync-engine and check how the performance is
- continue work on 
- new benchmarks