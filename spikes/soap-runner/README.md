# SOAP-runner spike

`app/` is the spike app **MUT SOAP Runner Spike** (object ids 50700-50702, SOAP service `MUTSpikeRunner`). Mutation
Core 1.1.x (`core-app/`, service `MUTRunner`, SPEC §6.10) supersedes it; nothing uses it any more, and it may be
uninstalled from mut-spike-02. `Test-MutRunnerLive.ps1` checks the real `MUTRunner` service; never run it during a
mutation run (it takes the environment lock).
