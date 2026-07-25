# Learning Journal — building an enterprise Kubernetes platform from scratch

This document is the **teaching companion** to the platform in this repo. Where
[`ARCHITECTURE.md`](ARCHITECTURE.md) describes *what* was built, this journal explains
*how and why* it was built, the **reasoning at each step**, **every bug we hit and how we
fixed it**, how each piece maps to **real enterprise and datacenter practice**, and a
**path to becoming an expert**.

Read it top to bottom once for the story; come back to the Bug Journal and Path-to-Expertise
sections as reference.

---

## 0. How to use this journal

- **Follow the story, then reproduce it.** Each phase has *the goal*, *the thinking*, *what
  we ran*, and *the enterprise parallel*. Try to explain each step back to yourself before
  moving on — if you can teach it, you know it.
- **The bugs are the real curriculum.** Anyone can copy commands that work. Expertise is
  built by understanding *why things break*. The [Bug Journal](#7-bug-journal--the-real-curriculum)
  is the most valuable section — study each one as: symptom → how we localized it → root
  cause → fix → the durable lesson.
- **Always know which layer you're in.** Almost every problem is faster to solve once you
  ask "which layer is this?" (hardware → virtualization → OS → runtime → control plane →
  networking → workload → edge). Keep that ladder in your head.

---

## 1. The mental model (build this first)

Kubernetes is a **control loop over a shared datastore**. That one sentence explains most
of it:

1. You declare *desired state* as objects (Deployments, Services, PVCs) via the **API
   server**.
2. The API server persists them in **etcd** (the database of record).
3. **Controllers** watch etcd through the API server and continuously act to make *reality*
   match *desired state* (create pods, attach volumes, program networking).
4. On each machine, the **kubelet** runs the pods it's been assigned via the **container
   runtime** (containerd), and a **CNI** (Cilium) gives them networking.

Everything else — storage drivers, ingress, GitOps, monitoring — is *more controllers and
more APIs* bolted onto that same loop. Once you see Kubernetes as "a reconciler in front of
a database," the rest is detail.

**Why this matters for expertise:** when something is wrong, you trace the loop — did the
object reach the API? Is it in etcd? Is the controller running? Did the kubelet get the
work? Did the runtime/CNI succeed? That trace is 80% of real troubleshooting.

---

## 2. The upfront decisions (and why)

Before touching a machine, we made three choices that shaped everything:

| Decision | Choice | Why (the expert reasoning) |
|----------|--------|----------------------------|
| **Distribution** | `kubeadm` | The vendor-neutral reference installer. You wire every component yourself, so the knowledge transfers to EKS/GKE/AKS/RKE2/OpenShift and to the CKA exam. k3s/Talos are great but hide the internals you're here to learn. |
| **Topology** | 1 control-plane + 2 workers, VIP from day 1 | Start small to learn the whole stack end-to-end, but put a **floating API endpoint** (kube-vip VIP) in front *immediately* so growing to HA later needs no re-issued certs. Cheap now, saves a rebuild later. |
| **Everything as code** | scripts + Git + CI | No "pet" servers. Every node is reproducible from a script; every change is a reviewed commit. This is the single biggest difference between a hobby cluster and a professional one. |

**Datacenter parallel:** real datacenters never hand-build servers. They PXE-boot from
images, configure with Ansible/Terraform, and treat machines as cattle. Our "golden VM
template + prep script" is the small-scale version of exactly that.

---

## 3. Phase 1 — Provisioning the nodes

**Goal:** three identical Linux VMs to become the cluster.

**The thinking:** identical, reproducible nodes matter more than anything fancy. We cloned
all three from one Proxmox template, put their disks on **shared Ceph** (so a VM can restart
on any host), gave them **static IPs** (Kubernetes hates changing node IPs — etcd and certs
bind to them), and turned **swap off** (the kubelet refuses swap because it breaks the
memory/eviction model).

**Enterprise parallel:** "golden image" provisioning. A cloud `LaunchTemplate` or a VMware
template is the same idea — bake a known-good base, stamp out identical instances.

**Datacenter parallel:** static addressing + shared storage is how VMs achieve *live
migration* and *fast restart on failure* — the foundation of datacenter availability.

---

## 4. Phase 2 — Preparing the hosts

**Goal:** make each Linux box able to *be* a Kubernetes node.

**The thinking — the kubelet has a contract with the OS:**
- **Kernel modules** `overlay` (union filesystem for container images) + `br_netfilter`
  (so bridged pod traffic passes through the firewall for policy).
- **sysctls** `ip_forward=1` (nodes route pod traffic) and `bridge-nf-call-iptables=1`.
- **A CRI runtime** — we installed **containerd** and set `SystemdCgroup=true` so the
  runtime and kubelet agree on *one* cgroup manager (a mismatch causes instability under
  load).
- **Version-pinned** kube tools, `apt-mark hold`'d so nodes never drift — **upgrades become
  a deliberate act, not an accident.**

**Enterprise parallel:** this is a "node bootstrap" role in Ansible/Ignition. Managed
services (EKS/GKE) do it for you inside their node images — but knowing the contract is what
lets you debug when a node won't join.

---

## 5. Phase 3 — The control plane (the hardest, most important phase)

**Goal:** bring up the brain — etcd, API server, scheduler, controllers — behind a stable
HA endpoint, plus pod networking.

**The thinking:**
- **kube-vip first.** We placed a tiny pod that raises a **virtual IP (`.59`)** and pointed
  the whole cluster's API endpoint at it. The cluster, worker kubelets, and future
  control-plane nodes all target `.59` — decoupled from any single machine. *This one
  decision is what makes HA a future afternoon instead of a rebuild.*
- **`kubeadm init`** generated the CA, certs (signed for both the node IP and the VIP),
  etcd, and the control-plane static pods, and uploaded certs so future control-plane joins
  are one command.
- **Cilium (CNI).** Until a pod network exists, nodes are `NotReady` and CoreDNS is
  `Pending` — *by design*. Cilium uses **eBPF** (programs in the Linux kernel) for
  high-performance networking, policy, and observability (Hubble). It's what modern
  enterprises run (GKE Dataplane V2 is Cilium).

**Enterprise parallel:** managed control planes (EKS/GKE/AKS) hide all of this behind a
cloud load balancer and a button. Doing it by hand is exactly what teaches you what that
button does — and what to check when a managed cluster misbehaves.

**Datacenter parallel:** the VIP is a software load balancer (like keepalived/VRRP in front
of HAProxy) — the classic datacenter pattern for "one address, many backends, no SPOF."

---

## 6. Phase 4 & 5 — Workers and storage

**Phase 4 (workers):** `kubeadm join` used a token + CA hash to securely enrol each worker;
the control plane auto-issued it a signed certificate. We proved the cluster with a smoke
test: deploy nginx, watch the **scheduler** spread replicas across both workers, resolve the
Service by DNS, and curl it pod-to-pod across nodes.

**Phase 5 (storage):** the enterprise-grade step. We gave Kubernetes **dynamic persistent
storage** on the existing Ceph cluster via **Ceph-CSI**:
- A **dedicated `k8s-rbd` pool** and a **scoped `client.k8s` cephx user** (access to *only*
  that pool — blast-radius isolation from the VM-disk pool).
- A default **StorageClass** so any `PersistentVolumeClaim` auto-provisions an RBD image.
- Proven end-to-end: PVC → ceph-csi created the RBD image in Ceph → a pod mounted
  `/dev/rbd0` and read/wrote a file.

**Why this is a big deal:** most homelabs fake persistence with `hostPath`. Real,
replicated, self-service block storage is what lets you run **databases and stateful
services** — the thing that separates a toy cluster from a platform.

**Enterprise/datacenter parallel:** this is exactly AWS EBS + the EBS CSI driver, or a
datacenter SAN + its CSI driver. The `PVC → StorageClass → CSI → backend` chain is
identical everywhere; only the backend changes.

---

## 7. Bug Journal — the real curriculum

Every one of these cost real time and taught something durable. Study them as a set — notice
how often the *symptom* was far from the *cause*, and how a disciplined "which layer?" trace
found it.

### Bug 1 — Cloned VM config "does not exist" on the wrong node
- **Symptom:** after `qm clone 9000 121 --target nodeE`, follow-up `qm set 121 …` failed:
  `Configuration file 'nodes/nodeD/qemu-server/121.conf' does not exist`.
- **Cause:** `qm` only manages VMs *owned by the node you're on*. The clone's config lives
  on the **target** node, not the source (template) node.
- **Fix:** run `qm set/resize/start` by SSH'ing to the *owning* node.
- **Lesson:** in a cluster, "where does this object live?" is a first-class question — for
  VMs *and* for pods.

### Bug 2 — A clone that looked dead was just slow
- **Symptom:** VM 121 didn't answer ping/SSH for 2+ minutes; looked like a failed clone.
- **Diagnosis:** the **serial console** showed cloud-init still running at 155s uptime.
- **Cause:** **I/O contention** — a parallel full-clone was saturating Ceph, so first-boot
  (snap seeding, growpart) crawled.
- **Lesson:** *never declare something dead without looking at its console/logs.* "Slow" and
  "broken" look identical from the outside. (Foreshadows the big I/O theme below.)

### Bug 3 — No DNS on the nodes
- **Symptom:** `curl https://dl.k8s.io` → "Could not resolve host"; but `ping 1.1.1.1`
  worked.
- **Diagnosis:** routing/NAT fine (ping by IP worked) → **DNS-only** failure.
- **Cause:** cloud-init set a static IP but **no nameserver**, so `systemd-resolved` had no
  upstream.
- **Fix:** a `resolved` drop-in with `DNS=1.1.1.1`, persisted.
- **Lesson:** split "is it the network or the name resolution?" immediately — ping an IP vs.
  resolve a name. It halves the search space in one step.

### Bug 4 — containerd 2.x moved the pause-image setting
- **Symptom:** our `sed` to set the sandbox (pause) image matched nothing.
- **Cause:** containerd **2.x** renamed the config: the pause image is now under
  `[plugins.'io.containerd.cri.v1.images'.pinned_images]` as `sandbox = …`, and being
  *pinned* it's already protected from garbage collection.
- **Lesson:** don't blind-`sed` config you haven't read. Inspect the actual file on the
  actual version — tooling assumptions rot between major versions.

### Bug 5 — kube-vip crashloop flapping the API (the subtle one)
- **Symptom:** during worker join, nodes bounced `Ready`↔`NotReady`; off-node `kubectl` gave
  `no route to host`; kube-vip had 7 restarts.
- **Diagnosis:** kube-vip logs showed it *renewing a leader-election lease through the API*,
  timing out, concluding it lost leadership, and **deleting its own VIP** — a vicious loop.
- **Cause:** kube-vip defaults leader election **on** in control-plane mode, even for a
  single node where it's pointless.
- **Fix:** `vip_leaderelection=false` so the single instance holds the VIP unconditionally
  (re-enable when we grow to 3 control-plane nodes).
- **Lesson:** **leader election needs a reachable API to renew a lease; if you gate the API
  behind the very thing doing the election, you build a doom loop.** Watch for these
  circular dependencies in HA components.

### Bug 6 — A "failed" install that actually succeeded
- **Symptom:** the Cilium install script "failed" (exit 1).
- **Cause:** only `cilium status --wait` timed out (4 min) because an image took 3m14s to
  pull under I/O load. Cilium itself came up and the node went `Ready`.
- **Lesson:** distinguish *"the thing failed"* from *"my wait timed out."* Check the actual
  end state, not just the exit code.

### Bug 7 — Distroless etcd has no shell
- **Symptom:** `kubectl exec etcd-… -- sh -c "…"` → `"sh": executable file not found`.
- **Cause:** the etcd image is **distroless** (no shell, tiny attack surface).
- **Fix:** exec the `etcdctl` **binary** directly, no shell wrapper.
- **Lesson:** modern secure images ship no shell — a security best practice you'll meet
  everywhere. Interact via binaries, not `sh -c`.

### Bug 8 — The big one: etcd on Ceph → control-plane instability
- **Symptom:** every heavy install (ceph-csi, and it would only get worse with Prometheus)
  made the API/VIP flap; ceph-csi's provisioner sidecars `CrashLoopBackOff`.
- **Diagnosis:** `top` showed **85% iowait** on the control-plane node; the provisioner
  crashes were the *same leader-election cascade* as kube-vip (lease renewals timing out
  when the API stalled).
- **Root cause:** **etcd's latency-critical fsyncs shared a Ceph-RBD (network) disk with
  container-image unpacking.** etcd is exquisitely sensitive to disk latency; under I/O
  contention it stalls, the API stalls, and every leader-electing component wobbles.
- **Fix:** **move etcd onto a local NVMe disk** (added a `local-lvm` disk, remounted
  `/var/lib/etcd` onto it via `/etc/fstab`), and bump the node's RAM for page cache. Backed
  up etcd first, kept the old data as a fallback, and validated persistence with a reboot.
- **Lesson (career-grade):** **etcd wants dedicated, low-latency local storage — never
  network/shared storage.** This is written in every production Kubernetes guide, and here
  you *felt why*. When multiple symptoms (VIP flaps, CSI crashes, slow joins) share one
  trigger (I/O load), suspect a **common root cause** rather than fixing each symptom.

**Meta-lesson across all bugs:** the symptom is rarely the cause. Localize by layer, read
the actual logs/console, and look for one root cause behind many symptoms.

---

## 8. How this maps to enterprise companies & products

| What we built | The enterprise equivalent | Why companies invest in it |
|---------------|---------------------------|----------------------------|
| kubeadm cluster | EKS / GKE / AKS / OpenShift / RKE2 | Run many services on shared infra with self-healing and rolling updates |
| kube-vip HA endpoint | Cloud LB in front of a managed control plane | Remove the API single-point-of-failure; meet uptime SLAs |
| Cilium + Hubble | GKE Dataplane V2, enterprise CNIs | Fast, secure, *observable* networking; zero-trust policy |
| Ceph-CSI storage | EBS/PD CSI, NetApp/Pure CSI | Run stateful services (DBs) with durable, self-service storage |
| GitOps repo + CI | Argo/Flux + GitHub Actions/GitLab CI | Auditable, reviewable, repeatable delivery — SOC2/compliance |
| Version pinning + IaC | Golden images, Terraform, Ansible | Reproducibility, safe upgrades, no snowflakes |

**Product angle:** this *is* the substrate under most modern SaaS. When a company ships a
web product, it's very often: containers → Kubernetes → CSI storage → ingress → observability
→ CI/CD. Learning this stack is learning how modern software is *operated*, not just written.

---

## 9. How this maps to datacenters

- **Pooling & multi-tenancy:** Proxmox pooling 5 boxes into one schedulable capacity is what
  a datacenter does at rack/row scale with a hypervisor or bare-metal scheduler.
- **Shared storage & failure domains:** Ceph's 3× replication across nodes mirrors datacenter
  storage tiers designed so a disk/host/rack loss doesn't lose data. Our `size=3, min_size=2`
  is a real availability-vs-cost tuning decision.
- **The control-plane/data-plane split:** etcd+API (control) vs. workers running workloads
  (data) is the same separation datacenters draw between management networks and workload
  networks.
- **North-south vs east-west traffic:** edge/ingress (Cloudflare→Caddy→ingress) is
  north-south; Cilium pod-to-pod is east-west. Datacenters engineer and secure these
  separately — and so do we (ingress at the edge, NetworkPolicy inside).
- **Blast-radius thinking:** scoped cephx users, dedicated pools, taints/labels — all are
  datacenter instincts: *contain the damage when (not if) something fails.*

---

## 10. How to become an expert in these fields

Expertise here is **breadth across layers + depth in debugging + reps**. A concrete path:

**Foundations (don't skip):**
1. **Linux internals** — processes, cgroups, namespaces, systemd, networking (`ip`, `ss`,
   `nft`), storage (`lsblk`, filesystems, fstab). Containers *are* Linux features; you
   cannot be senior here without solid Linux.
2. **Networking** — IP/subnets/routing, DNS, TLS, load balancing, L2 vs L3. Most "Kubernetes"
   problems are networking problems.
3. **TCP/IP + HTTP** enough to read a packet capture and a curl `-v`.

**Kubernetes proper:**
4. Rebuild this cluster **from scratch, twice**, the second time from memory. Break it on
   purpose and fix it.
5. Learn the objects deeply: Pod, Deployment, Service, PVC/PV/StorageClass, Ingress, RBAC,
   NetworkPolicy. For each, know *which controller* reconciles it.
6. **Certifications as a syllabus** (not the goal): **CKA** (administration), then **CKS**
   (security), optionally **CKAD** (developer). They force hands-on breadth.

**Beyond the cluster (platform/SRE):**
7. **IaC**: Terraform, Ansible, and **GitOps** (Argo/Flux) — infra as reviewed code.
8. **Observability**: Prometheus/Grafana/Loki + tracing; learn to define SLOs and alerts.
9. **Storage & databases on Kubernetes**: stateful sets, operators, backup/restore (Velero).
10. **Security**: RBAC, admission control (Kyverno/OPA), supply-chain (image signing), CIS
    benchmarks.

**The habits that actually make the expert:**
- **Always trace by layer.** Keep the ladder in your head; localize before you fix.
- **Read the logs/console, not the vibes.** Every bug above was solved by *looking*.
- **Look for one root cause behind many symptoms.** (Bug 8 is the archetype.)
- **Write it down.** This journal — and the project's memory files — are how a session's
  pain becomes next session's speed. Experts keep runbooks.
- **Prefer reversible, verify end-to-end.** Snapshot before risky changes; test through the
  real path (curl the public URL, not just localhost).
- **Reproduce, then automate.** If you did it twice by hand, script it.

**Great resources:** the official Kubernetes docs (genuinely excellent), the CNCF landscape,
Cilium/Ceph/etcd docs, "Kubernetes Up & Running," Brendan Gregg for Linux performance, and
the source code when docs run out.

---

## 11. Glossary (quick reference)

- **CRI** — Container Runtime Interface; how kubelet talks to containerd.
- **CNI** — Container Network Interface; the pod-networking plugin (Cilium).
- **CSI** — Container Storage Interface; the storage driver (Ceph-CSI).
- **etcd** — the consistent key-value store holding all cluster state.
- **static pod** — a pod the kubelet runs directly from a manifest file (etcd, apiserver,
  kube-vip), not scheduled via the API.
- **taint/toleration** — how nodes repel pods that don't explicitly tolerate them (keeps
  workloads off control-plane nodes).
- **PVC/PV/StorageClass** — a claim for storage / the provisioned volume / the template that
  provisions it.
- **VIP** — virtual IP; a floating address (kube-vip) that provides one stable API endpoint.
- **eBPF** — run sandboxed programs in the Linux kernel; Cilium's dataplane.
- **iowait** — CPU time spent waiting on disk I/O; the star villain of Bug 8.

---

*This journal is updated as the platform grows. Each new phase adds its story, its bugs, and
its enterprise/datacenter parallels here.*
