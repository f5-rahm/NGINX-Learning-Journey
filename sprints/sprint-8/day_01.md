# Sprint 8 &bull; Day 1: Kubernetes Networking for a BIG-IP Engineer, and Your First Ingress
**Day:** 1 of 3  
**Estimated Time:** 95 Minutes (20 concepts, 10 setup, 55 activities, 10 quiz)  
**Theme:** Until now NGINX has been a process you configured by hand. In Kubernetes nobody writes `nginx.conf`: you declare what you want (a host, a path, a service) and a **controller** writes NGINX's configuration for you, and rewrites it every time a pod comes or goes. Before that makes sense you need the network it lives in: pods that change addresses, Services that are only rules in every node's kernel, and endpoint lists that a readiness check decides. Today you build that picture with BIG-IP words, install **F5 NGINX Ingress Controller**, and read the NGINX configuration it generates from your first Ingress.

> **Which "NGINX ingress"?** This sprint uses **F5 NGINX Ingress Controller** (`nginx/kubernetes-ingress`, annotations `nginx.org/*`), which F5 develops and releases (5.8.0 came out on 18 November 2026). The community's **Ingress-NGINX** (`kubernetes/ingress-nginx`) is a different project, and it was retired in March 2026. Section 1.6 sorts the two out.

---

## 1. Concepts to Understand (20 Minutes)

No Kubernetes knowledge is assumed. Every object is mapped to the closest BIG-IP idea, and the mapping is only approximate, so watch for where it breaks.

### 1.1 The Cluster, in BIG-IP Words

| Kubernetes | What it is | Closest BIG-IP idea |
| :--- | :--- | :--- |
| **Cluster** | A set of machines run by one control plane (the API server and its database, etcd) | A device group, managed from one place |
| **Node** | One machine in the cluster. In this lab each node is a Docker container made by **kind** (Kubernetes in Docker). | A device |
| **Pod** | One running copy of an application: one or more containers sharing **one IP address**. Pods are disposable. | A pool member, but one that gets a new address every time it restarts |
| **Deployment** | "Keep N identical pods of this template running." It replaces pods that die and rolls out changes. | Nothing direct. Think of a pool that adds and replaces its own members. |
| **Label / selector** | Key-value tags on objects (`app=arrivals`, `version=v1`), and queries that match them | Pool membership defined by a query, not a list |
| **Namespace** | A folder for objects, with its own permissions | An administrative partition |
| **Manifest** | A YAML file describing objects. `kubectl apply -f file` sends it to the API server. | An AS3 declaration |

Kubernetes is **declarative**: you state the end result, and controllers keep comparing it with reality and fixing the difference ("reconciling"). If you delete a pod that a Deployment owns, a new one appears. That loop is also how the ingress controller works (1.5).

### 1.2 Pod Networking and the CNI
* **Every pod gets its own IP**, from a range assigned to its node (`10.244.1.0/24` on one node, `10.244.2.0/24` on another). Any pod can reach any other pod's IP directly, across nodes, **without NAT**. The **CNI** plugin (Container Network Interface; kind uses one called kindnet) sets up the interfaces and routes that make this true.
* **Pod IPs are not stable.** A restarted pod comes back with a new name and a new IP, often on another node. Nothing in Kubernetes is configured with pod IPs by hand. Something always looks them up.

### 1.3 Services and EndpointSlices: a VIP That Exists Nowhere
* **A Service** gives a set of pods (chosen by a label selector) one stable name and one virtual IP, the **ClusterIP** (here `10.96.x.x`), plus a DNS name: `arrivals.transit.svc.cluster.local`, or just `arrivals` from inside the same namespace.
* **No device owns the ClusterIP.** Nothing listens on it and nothing answers ARP for it. **kube-proxy**, a component on every node, writes kernel rules (iptables or nftables) that rewrite the destination of any packet sent to the ClusterIP into one pod's IP (DNAT), chosen at random. Every node has the same rules, so the "virtual server" is on every node at once, and it only works for traffic that starts inside the cluster.
* **The EndpointSlice** is the pool member list: the pod IPs behind a Service, each with a `ready` condition. Kubernetes keeps it up to date as pods come and go.
* **The readiness probe is the health monitor.** If a pod has one, the kubelet (the node's agent) checks it, and a pod that fails it is marked `ready: false` and stops receiving traffic. **A pod without a readiness probe counts as ready as soon as its container starts**, even if the application inside isn't listening yet.

### 1.4 Getting Traffic In From Outside
* **NodePort** opens the same port (30000–32767) on every node and forwards it to the Service.
* **LoadBalancer** asks the platform for an external address in front of the NodePorts. In a cloud, the cloud's load balancer provides it. On premises, something like MetalLB, or a BIG-IP managed by F5 **Container Ingress Services (CIS)**, plays that part.
* **`externalTrafficPolicy`** decides what a node does with traffic for a pod it doesn't host:
  * `Cluster` (the Kubernetes default): forward it to a pod on another node, **SNATing the client address** so replies come back the same way. The application sees a node address, not the client's.
  * `Local`: keep the client address, but **only nodes that run one of the pods answer**. The others drop the traffic.
* **In this lab:** your host's port **8098** (and **8099** for HTTPS) is mapped by kind to NodePort 30080 (30443) on the control-plane node, where the ingress controller runs.

### 1.5 What an Ingress Controller Is
* **An Ingress** is a Kubernetes object that says "requests for this host and path go to that Service." It's only data: on its own it does nothing.
* **An ingress controller** watches the API server for Ingresses (and, for F5's controller, its own custom resources, Day 2), Services, EndpointSlices and Secrets. It **translates them into NGINX configuration** and applies it.
* **F5 NGINX Ingress Controller is one pod with two parts:** a controller process (written in Go) and NGINX itself. The controller writes files into `/etc/nginx/conf.d/` and reloads NGINX. With NGINX Plus it can change upstream servers through the Plus API instead of reloading (the side quest).
* **It reads the EndpointSlices and writes pod IPs straight into `upstream` blocks.** Traffic goes from NGINX directly to a pod, without the ClusterIP or kube-proxy. That's what lets NGINX do real load balancing, retries and health tracking per pod. It also means every pod change is a configuration change.
* **An IngressClass** names a controller (`spec.controller`). A resource picks a controller with `ingressClassName`. Several controllers can live in one cluster, each with its own class.

### 1.6 Two Projects Called "NGINX Ingress"
People often mix these two up, and when the community project was retired, many assumed F5's controller went with it. It didn't.

| | **F5 NGINX Ingress Controller** (this sprint) | **Ingress-NGINX** (community) |
| :--- | :--- | :--- |
| Repository | `github.com/nginx/kubernetes-ingress` | `github.com/kubernetes/ingress-nginx` |
| Who maintains it | F5 (NGINX) | Kubernetes community volunteers |
| Status | **Active.** 5.8.0 released 18 Nov 2026, plus an LTS line. | **Retired.** Repository archived 24 Mar 2026. The final release was v1.15.1, and there are no more fixes, security fixes included. |
| Data plane | NGINX Open Source or NGINX Plus | NGINX with Lua modules (OpenResty-based) |
| Annotations | `nginx.org/*` (and `nginx.com/*` for Plus) | `nginx.ingress.kubernetes.io/*` |
| Custom resources | `VirtualServer`, `VirtualServerRoute`, `Policy`, `TransportServer` (`k8s.nginx.org`) | None |
| IngressClass `spec.controller` | `nginx.org/ingress-controller` | `k8s.io/ingress-nginx` |
| Default IngressClass name | `nginx` | `nginx` (the same, which adds to the confusion) |
| Image | `nginx/nginx-ingress` (Plus: `private-registry.nginx.com/nginx-ic/nginx-plus-ingress`) | `registry.k8s.io/ingress-nginx/controller` |

They share the standard Ingress object and nothing else. An Ingress written for one usually *applies* to the other without errors, which hides the problem until traffic misbehaves. Day 2 measures exactly that.

<details>
<summary>A colleague says: "NGINX ingress is dead, Kubernetes retired it, we have to move everything to Gateway API." What's right and what's wrong?</summary>

What's right: the **community** Ingress-NGINX controller is retired. Anyone still running it gets no security fixes and should migrate. What's wrong: F5 NGINX Ingress Controller is a separate, maintained product, and the **Ingress API itself isn't retired**. Kubernetes still ships it, it's just feature-frozen. Gateway API (Sprint 9) is the long-term direction, and F5 has NGINX Gateway Fabric for it. Moving from Ingress-NGINX to F5 NGINX Ingress Controller is one valid migration path, moving to Gateway API is another, and many teams do the first now and the second later.
</details>

### 1.7 BIG-IP Lens

| Need | BIG-IP | Kubernetes + F5 NGINX Ingress Controller |
| :--- | :--- | :--- |
| Pool members | Static list, or nodes discovered by CIS | EndpointSlice: pod IPs maintained by Kubernetes |
| Health monitor | Active monitor on the pool | The pod's readiness probe (run by the kubelet, not the load balancer); NGINX adds passive `max_fails` |
| Virtual server inside the network | VIP on a self IP or VLAN | ClusterIP: DNAT rules on every node, no listener anywhere |
| Virtual server for outside clients | VIP | NodePort / LoadBalancer Service → the ingress controller |
| SNAT automap | Per virtual server | `externalTrafficPolicy: Cluster` SNATs, `Local` doesn't |
| Configuration | tmsh / iControl / AS3 declaration | Ingress or VirtualServer manifests; the controller writes `nginx.conf` |
| Config sync and pool updates from Kubernetes | CIS watches the cluster and updates BIG-IP (NodePort mode, or ClusterIP mode with pod IPs as pool members) | The controller watches the cluster and rewrites its own NGINX's upstreams with pod IPs |

---

## 2. Lab Setup (10 Minutes)

### Where commands run
Everything today runs in a **terminal on the lab host**, in `/srv/nginx-journey/sprints/sprint-8/lab`, unless a step says otherwise. Each code block starts with a comment saying where it runs:

| Comment at the top of a block | Where |
| :--- | :--- |
| `# host, lab/` | The lab host, in `/srv/nginx-journey/sprints/sprint-8/lab`, after `source helpers.sh` |
| `# host, as root` | The lab host, as root, any directory |
| `# file: lab/work/NAME.yaml` | A file you create with your editor. `lab/work/` is yours: git ignores it. |

`kubectl` and `helm` commands go to the Kubernetes API server, wherever you run them from. When a command must run *inside* a pod or a node, the block does it explicitly with `kubectl exec` or `docker exec`, and the text says so.

### Step 0: The tools (once per lab box)
Sprint 8 needs `kind`, `kubectl` and `helm` (pinned versions; the README's one-time setup has the same step). Check:
```bash
# host, any directory
kind version; kubectl version --client; helm version --short
```
If any is missing:
```bash
# host, as root
curl -fsSLo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64
curl -fsSLo /usr/local/bin/kubectl https://dl.k8s.io/release/v1.37.0/bin/linux/amd64/kubectl
curl -fsSL https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz | tar -xz -C /usr/local/bin --strip-components=1 linux-amd64/helm
chmod +x /usr/local/bin/kind /usr/local/bin/kubectl
kind version; kubectl version --client; helm version --short
```
Expected: `kind v0.33.0`, `Client Version: v1.37.0`, `v4.3.1`. (On an arm64 box, replace `amd64` with `arm64` in the three URLs.)

### Step 1: Start the cluster, without the ingress controller
Today you install the controller yourself, so start the lab with `--no-nic`:
```bash
# host, any directory
cd /srv/nginx-journey/sprints/sprint-8/lab
./lab.sh up --no-nic
```
The first run takes 2–3 minutes (it downloads the node image). It creates the kind cluster `s8` and sets kubectl's context to `kind-s8`. It then makes the lab certificates (`lab/certs/`, used from Day 2) and deploys Copperline Transit's applications. It ends with `Lab ready` and `NGINX Ingress Controller not installed`.

### Step 2: Load the helpers
```bash
# host, lab/
source helpers.sh
s8help
```
Do this in **every new terminal** you open for the lab. The request helpers all run curl on the host: `hreq` and `hwho` go to the controller's HTTP port 8098, `t` and `who` to its HTTPS port 8099 (from Day 2), and `incluster` runs curl from a pod.

**Copperline Transit, the company:** a city transit agency. Namespace `transit` holds the public website (`web`), the arrivals API (`arrivals`, version v1, plus a v2 for Day 3), and the dispatchers' console (`dispatch`). Namespace `fares` belongs to the fares team. Every app is the same small Python program (`lab/app.py`), and every answer is JSON saying which app, version, pod and node served it.

---

## 3. Hands-on Guided Discovery Activities (55 Minutes)

### Activity 3.1: Meet the Cluster (8 min)
```bash
# host, lab/
kubectl get nodes -o wide
docker ps --filter name=s8- --format '{{.Names}}  {{.Image}}  {{.Ports}}'
kubectl get namespaces
```
Three nodes, `s8-control-plane`, `s8-worker` and `s8-worker2`, each a Docker container on your host. Only the control-plane container publishes ports: 8098, 8099, 8086 and 8087 on all host addresses, plus the API server on a random localhost port.

```bash
# host, lab/
kubectl get nodes -o custom-columns=NODE:.metadata.name,POD-RANGE:.spec.podCIDR
kubectl -n transit get deployments
kubectl -n transit get pods -o wide
kubectl -n transit get pods --show-labels
```
`-n transit` means "in namespace transit". Each node has its own pod range, and each pod's IP comes from the range of the node it runs on.

<details>
<summary>The arrivals pods show <code>READY 1/1</code> within a second of starting, but <code>lab/k8s/transit.yaml</code> says the app takes 3 seconds to start listening. Why the mismatch?</summary>

`READY` means "the container is running and its readiness probe (if any) passes". The arrivals Deployment has **no readiness probe**, so Kubernetes considers the pod ready as soon as the process starts, while the app is still sleeping through its 3-second start. Compare `web`, which has a probe. Day 3 measures what that costs during a rollout.
</details>

### Activity 3.2: Pods Come and Go (5 min)
Delete one arrivals pod and watch the Deployment replace it:
```bash
# host, lab/
kubectl -n transit get pods -l app=arrivals,version=v1 -o wide
kubectl -n transit delete pod "$(kubectl -n transit get pods -l app=arrivals,version=v1 -o jsonpath='{.items[0].metadata.name}')"
kubectl -n transit get pods -l app=arrivals,version=v1 -o wide
kubectl -n transit get replicasets
```
`-l app=arrivals,version=v1` selects pods by label. A new pod appears straight away, with a new name, a new IP, maybe on the other worker. The ReplicaSet (the Deployment's helper that counts pods) briefly shows `READY 2` against `DESIRED 3`.

<details>
<summary>Anything that had the deleted pod's IP configured is now wrong. Who is responsible for noticing?</summary>

Whoever uses pod IPs must watch for changes. Kubernetes updates the EndpointSlice within moments. kube-proxy rewrites the node rules from it, and an ingress controller rewrites its NGINX upstreams from it (3.7). With BIG-IP in front of a cluster, CIS does the watching. Nobody should ever type a pod IP into a configuration.
</details>

### Activity 3.3: A Service Is a Rule, Not a Listener (10 min)
```bash
# host, lab/
kubectl -n transit get services
kubectl -n transit get endpointslices
kubectl -n transit get endpointslices -l kubernetes.io/service-name=arrivals \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} {.nodeName} ready={.conditions.ready}{"\n"}{end}'
```
The `arrivals` Service has a ClusterIP (`10.96.x.x`), and its EndpointSlice lists the three v1 pod IPs. Now try the ClusterIP from the host, then from a pod:
```bash
# host, lab/
curl -s -m 3 "http://$(kubectl -n transit get service arrivals -o jsonpath='{.spec.clusterIP}')/x"; echo "curl exit code: $?"
for i in 1 2 3 4 5 6; do incluster http://arrivals.transit.svc.cluster.local/x | jq -r .pod; done | sort | uniq -c
incluster http://arrivals/x | jq -c '{pod, client}'
```
From the host: exit code 28, a timeout. From the `client` pod (its curl runs **inside** the cluster), the requests are spread over the pods, and the short name `arrivals` works because the client pod is in the same namespace. The app sees the client pod's own IP as `client`: no SNAT inside the cluster.

<details>
<summary>Why does the ClusterIP work from a pod but not from the host?</summary>

Because the ClusterIP only exists in kube-proxy's rules on the nodes (and the host isn't a node). The host has no route to `10.96.0.0/12`, and even if it did, no rule on the host would rewrite the destination. Packets from a pod pass through its node's rules, which DNAT them to a pod IP.
</details>

Now look at the rules themselves, **inside a node**: `docker exec` runs the command in the `s8-worker` container.
```bash
# host, lab/ (the command runs inside the node container s8-worker)
docker exec s8-worker iptables-save | grep 'transit/arrivals:http' | grep -v MASQ
```
You'll see one `KUBE-SERVICES` rule matching the ClusterIP, a `KUBE-SVC-...` chain with `--probability 0.333…`, then `0.5`, then no condition, and one `KUBE-SEP-...` DNAT rule per pod.

<details>
<summary>What load-balancing method is that, and what can't it do that a BIG-IP pool can?</summary>

Random, per new connection: the first rule takes one third of connections, the second takes half of the rest, and the last takes everything left, so each pod gets a third. There's no health monitor of its own (it trusts the EndpointSlice), no least-connections, no retries, no persistence by cookie, and no L7 at all. It's a connection-level DNAT. That's why an ingress controller bypasses it and balances to pod IPs itself.
</details>

### Activity 3.4: Readiness Decides Membership (6 min)
`web` has a readiness probe on `/healthz`. Tell one web pod to fail it. `pod-unready` asks the app itself, through `kubectl exec`, to answer 503 on `/healthz`:
```bash
# host, lab/
pod-unready web on
sleep 3
kubectl -n transit get pods -l app=web
kubectl -n transit get endpointslices -l kubernetes.io/service-name=web \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}'
for i in 1 2 3 4 5 6; do incluster http://web/x | jq -r .pod; done | sort | uniq -c
pod-unready web off
```
The pod shows `0/1`, its endpoint `ready=false`, and all six requests go to the other pod. The pod wasn't restarted: it's alive but out of rotation, like a pool member marked down by its monitor.

Now the same for arrivals, which has no probe:
```bash
# host, lab/
pod-unready arrivals on
sleep 3
kubectl -n transit get endpointslices -l kubernetes.io/service-name=arrivals \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}'
pod-unready arrivals off
```

<details>
<summary>Before you run it: will the arrivals endpoint go <code>ready=false</code>?</summary>

No. All three stay `ready=true`. Without a readiness probe nothing asks the app, so its `/healthz` answer is never seen. A pool with no monitor keeps sending traffic to a member that says it isn't ready.
</details>

### Activity 3.5: Install F5 NGINX Ingress Controller (8 min)
The controller is installed with **Helm**, Kubernetes' package manager. A *chart* is a package of manifest templates, and a *values file* fills in the template's settings. Look at the lab's values file first:
```bash
# host, lab/
cat nic-values.yaml
```
It pins the image `nginx/nginx-ingress:5.8.0` (F5's image), names the IngressClass `nginx`, exposes the controller with a NodePort Service on 30080/30443 (kind maps those to the host's 8098/8099), and pins the pod to the control-plane node. Install it:
```bash
# host, lab/
helm install nic oci://ghcr.io/nginx/charts/nginx-ingress --version 2.9.0 \
  --namespace nginx-ingress --create-namespace -f nic-values.yaml --wait
```
`nic` is the release name. The chart comes from F5's OCI registry on `ghcr.io`, chart version 2.9.0, which is NIC 5.8.0. `--wait` returns when the pod is ready (about 10 seconds). Look at what it created:
```bash
# host, lab/
kubectl -n nginx-ingress get pods,services -o wide
kubectl get ingressclass
kubectl get crds | grep nginx.org
nconf
curl -si http://127.0.0.1:8098/ | head -4
./lab.sh check
```
* One pod on `s8-control-plane`, and a NodePort Service `80:30080, 443:30443`.
* IngressClass `nginx` with controller `nginx.org/ingress-controller`: F5's controller, not the community one.
* The custom resource definitions (CRDs) `virtualservers`, `virtualserverroutes`, `policies`, `transportservers`, `globalconfigurations` (Day 2), installed by the chart.
* `nconf` lists the controller's generated files in `/etc/nginx/conf.d/` (it runs `kubectl exec` into the controller pod): only `_default-server.conf` so far.
* Port 8098 answers `404` with `Server: nginx/1.31.9`. That's the default server, because no Ingress exists yet.

<details>
<summary>How would you know, from <code>kubectl get ingressclass</code> alone, which of the two "NGINX ingress" projects a cluster runs?</summary>

The `CONTROLLER` column. `nginx.org/ingress-controller` is F5 NGINX Ingress Controller, and `k8s.io/ingress-nginx` is the retired community Ingress-NGINX. The class *name* (`nginx`) tells you nothing, because both use it by default. `kubectl get pods -A -o jsonpath='{..image}'` is a second check: `nginx/nginx-ingress` vs `registry.k8s.io/ingress-nginx/controller`.
</details>

### Activity 3.6: Your First Ingress (10 min)
Create this file with your editor:
```yaml
# file: lab/work/day1-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: transit
  namespace: transit
spec:
  ingressClassName: nginx            # handled by F5 NGINX Ingress Controller (3.5)
  rules:
  - host: transit.copperline.test
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web
            port:
              number: 80
      - path: /arrivals
        pathType: Prefix
        backend:
          service:
            name: arrivals
            port:
              number: 80
```
Apply it and send requests. There's no DNS for `transit.copperline.test`, so the helpers send the `Host` header to `127.0.0.1:8098`:
```bash
# host, lab/
kubectl apply -f work/day1-ingress.yaml
kubectl -n transit get ingress
kubectl -n transit describe ingress transit
hreq transit.copperline.test /arrivals/next
hwho 9 transit.copperline.test /arrivals/next
hwho 3 transit.copperline.test /
```
`describe` shows each path's backend pod IPs and an event `AddedOrUpdated` from `nginx-ingress-controller`. The arrivals answers come from all three v1 pods. The headers the app received include `X-Real-IP` and `X-Forwarded-*`, which the controller adds.

Now read the NGINX configuration the controller wrote for your Ingress:
```bash
# host, lab/
nconf
nconf transit-transit.conf
kubectl -n transit get endpointslices -l kubernetes.io/service-name=arrivals -o jsonpath='{.items[*].endpoints[*].addresses[0]}'; echo
kubectl -n transit get service arrivals -o jsonpath='{.spec.clusterIP}'; echo
```
The file is named `<namespace>-<ingress name>.conf`. It has one `upstream` per Service, one `server` with `server_name transit.copperline.test`, and a `location` per path.

<details>
<summary>Find the arrivals <code>upstream</code>. Which addresses are in it, which load-balancing method, and where is the Service's ClusterIP?</summary>

The `server` lines are the **pod IPs** from the EndpointSlice (port 8080, the container port), not the ClusterIP, which appears nowhere. The method is `random two least_conn` (pick two pods at random and send to the one with fewer active connections): that's the controller's choice, since NGINX on its own would round-robin. Each server has `max_fails=1 fail_timeout=10s`, NGINX's own defaults written out: one failed attempt and the pod is skipped for 10 seconds. In BIG-IP terms, CIS in ClusterIP mode would build the same pool.
</details>

### Activity 3.7: Pods Change, NGINX Reloads (5 min)
`reloads` reads the controller's Prometheus metrics: how many times it reloaded NGINX, and why.
```bash
# host, lab/
reloads
kubectl -n transit scale deployment arrivals-v1 --replicas=5
kubectl -n transit rollout status deployment arrivals-v1
sleep 3; reloads
nconf transit-transit.conf | grep -c 'server 10.244'
kubectl -n transit scale deployment arrivals-v1 --replicas=3
sleep 6; reloads
```
`reason="other"` counts reloads for configuration changes (your Ingress), and `reason="endpoints"` counts reloads because pod IPs changed. Scaling up added 2 or so endpoint reloads. Scaling down added more, because each departing pod changes state more than once (ready, then terminating, then gone). The `grep -c` shows 7 server lines: 5 arrivals pods plus 2 web pods.

<details>
<summary>Why does NGINX Open Source need a reload for a new pod at all, and why doesn't the controller reload once per pod?</summary>

NGINX Open Source reads its `upstream` servers from the configuration file only, so a new pod IP means a new file and a reload: new workers start with the new configuration, and old workers finish their open requests and exit. The controller batches changes that arrive close together (a 2-second window in 5.8, `controller.batchReloadWindow`), so five pods starting together cost one or two reloads, not five. NGINX Plus can add and remove servers through its API without any reload: that's in the side quest.
</details>

### Activity 3.8: Three Edges of the Ingress (8 min)
**Prefix matching.** Predict which app answers each path before you run it:
```bash
# host, lab/
for p in /arrivals /arrivals/next /arrivalsboard /Arrivals; do
  printf '%-16s %s\n' $p "$(curl -s -H 'Host: transit.copperline.test' http://127.0.0.1:8098$p | jq -r .app)"
done
curl -s -o /dev/null -w 'unknown host: %{http_code}\n' -H 'Host: www.copperline.test' http://127.0.0.1:8098/arrivals/next
```

<details>
<summary>Answer: which one surprises, and why?</summary>

`/arrivalsboard` goes to **arrivals**. The Kubernetes spec defines `Prefix` as element-wise (`/arrivals` should match `/arrivals` and `/arrivals/...` but not `/arrivalsboard`), but the controller wrote `location "/arrivals"`, an NGINX prefix match on characters, so anything starting with those 9 characters matches. `/Arrivals` goes to **web**: matching is case-sensitive, so it falls through to `/`. An unknown host gets the default server's `404`. If the element boundary matters, use a path ending in `/` (`/arrivals/`), or VirtualServer's exact and regex matches (Day 2).
</details>

**The client's address.** Look at what the app saw:
```bash
# host, lab/
curl -s -H 'Host: transit.copperline.test' http://127.0.0.1:8098/arrivals/x | jq -c '{client, real_ip: .headers."X-Real-IP"}'
```
`client` is the controller pod (`10.244.0.x`), because NGINX opens its own connection to the pod. `X-Real-IP` is what NGINX saw as *its* client: `10.244.0.1`, a cluster address, not your host. The NodePort Service SNATed you (`externalTrafficPolicy: Cluster`). Switch the controller's Service to `Local` (`kubectl patch` changes one field of a live object):
```bash
# host, lab/
kubectl -n nginx-ingress patch service nic-nginx-ingress-controller -p '{"spec":{"externalTrafficPolicy":"Local"}}'
sleep 2
curl -s -H 'Host: transit.copperline.test' http://127.0.0.1:8098/arrivals/x | jq -c '{real_ip: .headers."X-Real-IP"}'
```
Now it's `172.19.0.1`: the Docker network's gateway, which is your host as the kind nodes see it. The client address survived. Next, call the NodePort on **each node** from a throwaway container on kind's Docker network (`docker run --network kind`), the way an external load balancer would:
```bash
# host, lab/ (each curl runs in a temporary container on the Docker network "kind")
for n in s8-control-plane s8-worker s8-worker2; do
  docker run --rm --network kind curlimages/curl:8.16.0 -s -m 3 -o /dev/null -w "$n:30080 %{http_code}\n" \
    -H 'Host: transit.copperline.test' http://$n:30080/arrivals/x || echo "$n:30080 no answer"
done
```

<details>
<summary>Before you run it: which nodes answer with <code>Local</code>?</summary>

Only `s8-control-plane`, the one running the controller pod. The workers have no local endpoint for that Service, so with `Local` they drop the traffic and curl times out. A load balancer in front of a `Local` Service must health-check each node (for `LoadBalancer` Services, Kubernetes opens a `healthCheckNodePort` for exactly that), or it sends clients into a black hole. That's the trade: `Cluster` answers everywhere but SNATs, `Local` keeps the client IP but needs a health-aware load balancer.
</details>

Put it back, since the rest of the sprint uses `Cluster`:
```bash
# host, lab/
kubectl -n nginx-ingress patch service nic-nginx-ingress-controller -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
```

---

## 4. Day 1 Concept Examination (10-Question Randomized Quiz)

```bash
# host, any directory (a second terminal; leave it running)
cd /srv/nginx-journey && python3 -m http.server 8090
```
👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=8&day=1**

When you're done, either leave the cluster up for Day 2 (it uses about 1.5 GB) or stop it with `./lab.sh down` (from `lab/`). Day 2's setup works either way.

---

## 5. Key Takeaways for Day 1
* **Pods are disposable and so are their IPs.** Deployments keep the count, EndpointSlices keep the list, and nothing is configured with a pod IP by hand.
* **A ClusterIP is a set of DNAT rules on every node**, random per connection, with no listener and no health monitor of its own.
* **Readiness probes decide membership.** No probe means "ready" the moment the container starts.
* **F5 NGINX Ingress Controller writes pod IPs straight into NGINX upstreams**, bypassing kube-proxy, with `random two least_conn` and `max_fails=1 fail_timeout=10s` by default. Open source NGINX reloads for every batch of endpoint changes.
* **`externalTrafficPolicy`:** `Cluster` SNATs the client, and `Local` keeps the address but only nodes with a controller pod answer.
* **Two different projects:** F5 NGINX Ingress Controller (`nginx.org/ingress-controller`, active) and community Ingress-NGINX (`k8s.io/ingress-nginx`, retired March 2026). Check the IngressClass controller, not the class name.
