import Darwin
import VitalsCore
import VitalsKernel

// Proves the name memoization: capture A warms the cache, capture B must not
// re-read (no proc_name refetches beyond newborn pids) and must hand back the
// very same String storage capture A produced. CLT-only machines have no
// XCTest/swift-testing, so this is a plain executable: swift run selftest

func fail(_ message: String) -> Never {
    print("FAIL  \(message)")
    exit(1)
}

guard case let .success(first) = Sampler.capture() else { fail("capture A errored") }
let fetchesAfterA = Sampler.nameFetches.withLock { $0 }
guard case let .success(second) = Sampler.capture() else { fail("capture B errored") }
let refetched = Sampler.nameFetches.withLock { $0 } - fetchesAfterA

print("ok    capture A: \(first.processes.count) processes, \(fetchesAfterA) name fetches")
print("ok    capture B: \(second.processes.count) processes, \(refetched) name fetches")

guard second.processes.count > 100 else { fail("implausibly few processes sampled") }
guard second.disk.freeBytes <= second.disk.totalBytes else {
    fail("immediate disk capacity exceeds total capacity")
}
guard second.disk.availableBytes <= second.disk.totalBytes else {
    fail("important-usage disk capacity exceeds total capacity")
}
guard refetched < second.processes.count / 10 else {
    fail("capture B re-read \(refetched) names — memoization not effective")
}
print(
    "ok    disk: \(second.disk.availableBytes) bytes available for important usage, "
        + "\(second.disk.freeBytes) bytes free now"
)

// Object identity: only observable for heap-backed strings; names within
// Swift's 15-byte small-string limit live inline and never allocate.
let firstNames = Dictionary(
    first.processes.map { ($0.pid, $0.name) },
    uniquingKeysWith: { name, _ in name }
)
var checked = 0
var shared = 0
for process in second.processes where process.name.utf8.count > 15 {
    guard var nameA = firstNames[process.pid] else { continue }
    var nameB = process.name
    let baseA = nameA.withUTF8 { UInt(bitPattern: $0.baseAddress) }
    let baseB = nameB.withUTF8 { UInt(bitPattern: $0.baseAddress) }
    checked += 1
    if baseA == baseB { shared += 1 }
}

guard checked > 0 else { fail("no heap-backed names to compare") }
guard shared == checked else {
    fail("identity: only \(shared)/\(checked) names share storage — copies were made")
}
print("ok    identity: \(shared)/\(checked) heap-backed names are the same object as capture A's")

func process(_ cpu: Double, name: String = "worker") -> ProcessView {
    ProcessView(
        pid: 42,
        ppid: 1,
        name: name,
        cpuPercent: cpu,
        footprintBytes: 1,
        residentBytes: 1
    )
}

var smoother = ProcessCPUSmoother(response: 0.3)
let baseline = smoother.smooth([process(10)])[0].cpuPercent!
let burst = smoother.smooth([process(110)])[0].cpuPercent!
let recovery = smoother.smooth([process(10)])[0].cpuPercent!
guard baseline == 10 else { fail("smoother changed its baseline") }
guard abs(burst - 40) < 0.001 else { fail("smoother did not damp a one-sample burst") }
guard abs(recovery - 31) < 0.001 else { fail("smoother did not decay predictably") }

var multicore = ProcessCPUSmoother(response: 0.3)
guard multicore.smooth([process(180)])[0].cpuPercent == 180 else {
    fail("smoother capped a valid multicore value")
}

_ = smoother.smooth([])
guard smoother.smooth([process(90)])[0].cpuPercent == 90 else {
    fail("smoother retained a terminated process")
}
guard smoother.smooth([process(120, name: "replacement")])[0].cpuPercent == 120 else {
    fail("smoother mixed different process identities")
}
print("ok    process CPU smoothing dampens bursts without capping multicore usage")

// 60 s window: a process idling at 5% that spikes to 300% for one sample
// every 10 samples must keep the spike in its ring, rank above a steady 50%
// worker, and linger for `grace` samples after it exits.
var history = ProcessCPUHistory(capacity: 30, grace: 5)
func worker(_ pid: Int32, _ cpu: Double, name: String) -> ProcessView {
    ProcessView(pid: pid, ppid: 1, name: name, cpuPercent: cpu, footprintBytes: 1, residentBytes: 1)
}
for tick in 0..<30 {
    let bursty = worker(7, tick % 10 == 9 ? 300 : 5, name: "bursty")
    history.record([bursty, worker(8, 50, name: "steady")])
}
let ranked = history.tracks()
guard ranked.map(\.last.name) == ["bursty", "steady"] else {
    fail("history ranked by latest value, not by window peak: \(ranked.map(\.last.name))")
}
guard ranked[0].peak == 300, ranked[0].samples.count == 30,
      ranked[0].samples.filter({ $0 == 300 }).count == 3 else {
    fail("burst samples were lost from the ring")
}
guard ranked[0].samples.last == 300, ranked[0].samples.first == 5 else {
    fail("ring is not ordered oldest to newest")
}
guard ranked[0].isAlive else { fail("live process reported as exited") }
for _ in 0..<5 {
    history.record([worker(8, 50, name: "steady")])
}
guard let lingering = history.track(ProcessCPUHistory.Identity(worker(7, 0, name: "bursty"))),
      !lingering.isAlive, lingering.samples.suffix(5).allSatisfy({ $0 == nil }) else {
    fail("exited process did not linger for the grace period")
}
history.record([worker(8, 50, name: "steady")])
guard history.track(ProcessCPUHistory.Identity(worker(7, 0, name: "bursty"))) == nil else {
    fail("exited process outlived the grace period")
}
let grouped = history.series([
    ProcessCPUHistory.Identity(worker(8, 0, name: "steady")),
    ProcessCPUHistory.Identity(worker(9, 0, name: "absent"))
])
guard grouped.count == 30, grouped.allSatisfy({ $0 == 50 }) else {
    fail("group series did not sum member windows")
}
print("ok    60 s history keeps one-sample bursts visible and ranks by window peak")

// nettop parsing and per-interval rates. Process names may contain dots.
let nettopA = """
,bytes_in,bytes_out,
launchd.1,0,0,
com.apple.WebKit.Networking.4242,1000,500,
Claude.777,20000,3000,
garbage line
"""
let nettopB = """
,bytes_in,bytes_out,
launchd.1,0,0,
com.apple.WebKit.Networking.4242,3000,500,
Claude.777,10000,4000,
"""
let frameA = NetworkFrame(monotonicNanos: 0, counters: Network.parse(nettopA))
let frameB = NetworkFrame(monotonicNanos: 2_000_000_000, counters: Network.parse(nettopB))
guard frameA.counters.count == 3, frameA.counters[4242] == NetworkCounters(bytesIn: 1000, bytesOut: 500) else {
    fail("nettop parser mis-read a dotted process name: \(frameA.counters)")
}
let rates = Network.rates(previous: frameA, current: frameB)
guard rates[4242] == NetworkRate(inPerSecond: 1000, outPerSecond: 0) else {
    fail("network rate is not bytes per second over the interval: \(String(describing: rates[4242]))")
}
guard rates[777] == nil else { fail("a counter that went backwards was reported as a rate") }
guard Network.groupRate(pids: [1, 4242, 9], in: rates) == NetworkRate(inPerSecond: 1000, outPerSecond: 0),
      Network.groupRate(pids: [9], in: rates) == nil else {
    fail("group rate did not sum only the members with readings")
}
print("ok    nettop counters become per-interval rates, resets are dropped")

// Awake policy: holds only when the mode's condition is met, arms the
// lid-close override before the lid closes but never without a display
// unless Always, warns when the lid will still sleep, and is pure.
let docked = PowerContext(lidClosed: true, lidClosesSleep: false, source: .ac, externalDisplays: 1)
let unplugged = PowerContext(lidClosed: true, lidClosesSleep: true, source: .battery, externalDisplays: 0)
let open = PowerContext(lidClosed: false, lidClosesSleep: true, source: .battery, externalDisplays: 0)
let openDocked = PowerContext(lidClosed: false, lidClosesSleep: true, source: .battery, externalDisplays: 2)
guard Awake.decide(mode: .off, context: docked) == AwakeDecision(holdSystem: false, holdDisplay: false, overrideLidSleep: false, reason: "off", warning: false) else {
    fail("off mode must hold nothing")
}
guard Awake.decide(mode: .lidClosed, context: docked) == AwakeDecision(holdSystem: true, holdDisplay: true, overrideLidSleep: true, reason: "holding · lid closed · AC · 1 external display", warning: false) else {
    fail("lid-closed mode did not hold in the docked case: \(Awake.decide(mode: .lidClosed, context: docked))")
}
guard Awake.decide(mode: .lidClosed, context: openDocked) == AwakeDecision(holdSystem: false, holdDisplay: false, overrideLidSleep: true, reason: "armed · lid open · battery · 2 external displays", warning: false) else {
    fail("lid-closed mode must arm the override before the lid closes: \(Awake.decide(mode: .lidClosed, context: openDocked))")
}
guard !Awake.decide(mode: .lidClosed, context: open).holdsAnything,
      Awake.decide(mode: .lidClosed, context: open).reason == "idle · lid open · battery · 0 external displays" else {
    fail("lid-closed mode held with the lid open and no display")
}
let bagged = Awake.decide(mode: .lidClosed, context: unplugged)
guard bagged.holdSystem, !bagged.overrideLidSleep, bagged.warning, bagged.reason.hasSuffix("lid close sleeps without a display") else {
    fail("lid-closed mode without a display must let a bagged Mac sleep: \(bagged)")
}
let headless = Awake.decide(mode: .always, context: unplugged)
guard headless.holdSystem, headless.overrideLidSleep, !headless.warning, headless.reason == "holding · lid closed · battery · 0 external displays" else {
    fail("always must override lid sleep on battery too: \(headless)")
}
guard Awake.decide(mode: .externalDisplay, context: open).holdsAnything == false,
      Awake.decide(mode: .externalDisplay, context: docked) == AwakeDecision(holdSystem: true, holdDisplay: true, overrideLidSleep: true, reason: "holding · lid closed · AC · 1 external display", warning: false) else {
    fail("external-display mode follows the display count")
}
let live = PowerSampler.context()
print("ok    awake policy: lid \(live.lidClosed ? "closed" : "open"), \(live.source.rawValue), \(live.externalDisplays) external, lid-sleep \(live.lidClosesSleep)")

let gib: UInt64 = 1_073_741_824
let alarmSnapshot = Snapshot(
    cpuPercent: 0,
    attributedCpuPercent: 0,
    cores: 1,
    memory: MemoryView(
        total: gib,
        wired: 0,
        compressed: 0,
        app: 0,
        cachedFiles: 0,
        free: gib,
        available: gib,
        used: 0,
        swapRate: 0,
        swapUsed: 0,
        swapTotal: 0,
        pressure: .green
    ),
    disk: DiskView(
        free: 5_000_000_000,
        available: 20_000_000_000,
        total: 100_000_000_000
    ),
    processes: []
)
let diskDecision = Derive.evaluateAlarms(
    snapshot: alarmSnapshot,
    thresholds: Thresholds(
        diskAvailableBytes: 10_000_000_000,
        diskRecoverAvailableBytes: 12_000_000_000
    ),
    previous: AlarmState()
)
guard !diskDecision.state.diskFiring else {
    fail("disk alarm used immediately free space instead of important-usage capacity")
}
print("ok    disk alarm follows important-usage capacity")

// Signals: Stop parks a child in SSTOP and Resume brings it back. Uses a
// real `sleep` so the round trip goes through the kernel, not a mock.
func processStatus(_ pid: pid_t) -> UInt32 {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info.pbi_status : 0
}
func waitStatus(_ pid: pid_t, stopped: Bool) -> Bool {
    for _ in 0..<50 {
        if (processStatus(pid) == UInt32(SSTOP)) == stopped { return true }
        usleep(20_000)
    }
    return false
}
var child: pid_t = 0
var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
guard posix_spawn(&child, "/bin/sleep", nil, nil, &argv, environ) == 0, child > 0 else {
    fail("could not spawn the signal test child")
}
guard case .success = Signals.send(Signals.stop, to: child), waitStatus(child, stopped: true) else {
    fail("Stop did not park pid \(child) in SSTOP (status \(processStatus(child)))")
}
guard case .success = Signals.send(Signals.resume, to: child), waitStatus(child, stopped: false) else {
    fail("Resume did not bring pid \(child) out of SSTOP (status \(processStatus(child)))")
}
_ = Signals.send(Signals.force, to: child)
var exitStatus: Int32 = 0
waitpid(child, &exitStatus, 0)
argv.forEach { free($0) }
print("ok    signals: Stop parks a child in SSTOP, Resume releases it")
print("PASS  memoization verified: nothing re-read")
