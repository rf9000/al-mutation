# SOAP-runner spike

`app/` is the spike app **MUT SOAP Runner Spike** (object ids 50700-50702, SOAP service `MUTSpikeRunner`). Mutation
Core 1.1.x (`core-app/`, service `MUTRunner`, SPEC §6.10) supersedes it; nothing uses it any more. It was unpublished
from mut-spike-02 on 2026-10-06. Its `MUTSpikeRunner` tenant web-service entry may remain and point at a missing
codeunit, which is harmless. The scripts `Invoke-SoapRunnerSpike.ps1`, `Invoke-SoapTimeoutSpike.ps1` and
`Invoke-SoapSoak.ps1` need the spike app, so they no longer run as they are. `Test-MutRunnerLive.ps1` checks the real `MUTRunner` service; never run it during a
mutation run (it takes the environment lock).
