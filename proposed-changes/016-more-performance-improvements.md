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