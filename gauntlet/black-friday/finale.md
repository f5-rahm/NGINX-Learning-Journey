# Finale: Midnight

**Ticket 9** · Everything at once · [War room README](README.md)

---

## Ticket 9: Midnight

> **From everyone:** The doors are open. Traffic is surging. Everything we fixed tonight has to hold.

`./warroom.sh next`, then `./warroom.sh check`:
* Sixteen background shoppers browse the catalog through the load balancer as fast as they can.
* Meanwhile, the checks for tickets 1–7 run again, including their mechanisms: a refresh or purge on both nodes, a test range through the API (Plus), a sustained checkout run, adding and removing a VIP.

**Requirements:**
1. Every fix from tickets 1–7 holds under load.
2. The rush sees no errors. Every background request gets a `200`.

**Scoring:** 200 points × (fixes that held ÷ 7), halved if shoppers saw errors. You can check again; the best run counts.

<details><summary>Hint</summary>

If a ticket that held before breaks now, look for what a later ticket changed:
* An `if` at the server level now runs before every location.
* A load balancer change moves shoppers between nodes.
* A restart emptied caches and shared memory.

`./warroom.sh check` printed which requirement failed.
</details>

---

## Debrief

### What You Changed, by Edition

| Ticket | Open source | NGINX Plus | What Plus changed |
| :--- | :--- | :--- | :--- |
| 1 | `proxy_cache_bypass` for ops: a refresh that overwrites | `proxy_cache_purge` for ops | A real delete, and a `PURGE` verb ops can script |
| 2 | Cache-key generations, a reload | Wildcard `PURGE`, no reload | Prefix invalidation without touching the key |
| 3 | `$upstream_cache_status` in the log, counted afterwards | API counters per zone, live | Numbers you can poll, export and graph |
| 4 | `geo` + an included file + a reload per change | Synced `keyval` changed through the API | No reloads, one change for every node |
| 5 | A more specific `geo` entry | A more specific key | The same model, no reload |
| 6 | Client affinity at the load balancer | `limit_req ... sync` | Shared counts, load stays spread |
| 7 | njs shared memory + an njs admin endpoint, per node | A synced `keyval` keyed by njs's result | Less code, one change for every node |

The pattern: **open source handles all of it.** It costs reloads, per-node runbooks, and code you write and protect yourself (ticket 7's endpoint). **Plus turns runtime state into data you change through an API, and `zone_sync` makes that data the cluster's, not the node's.** Caches stay per node in both editions.

### In BIG-IP Terms

| Tonight | BIG-IP |
| :--- | :--- |
| Cache per node, invalidated per node | Web Acceleration RAM cache, per device |
| `keyval` + API | Data groups / AFM address lists over iControl REST |
| `zone_sync` | Device-group sync, but for runtime data, not configuration |
| `limit_req` per node | L7 DoS and `table` limits, per device |
| njs + `keyval` | An iRule with `CRYPTO::verify` and `class match` |
| njs vs Lua/OpenResty | iRules vs iRules LX |

<details><summary>Question: of tonight's state, what was lost if both edges restarted at once, and what would you change before next Black Friday?</summary>

Lost:
* both caches
* every rate-limit count
* the VIP list (in the open source edition, also the njs shared dictionary)
* in the Plus edition, the key-value denylist and VIP list, because no node kept a copy and the zones have no state file

In the open source edition, the denylist survives in `denylist.conf`. Before next year:
* **Plus:** `state=` files for the key-value zones, so a restarted node starts from its last known data, and rolling restarts so the peer re-syncs.
* **Open source:** keep the VIP list somewhere durable and load it at start (for example with `js_periodic` and `ngx.fetch`), and keep cache lifetimes short enough that a cold cache isn't an incident.
</details>

---

## Clean Up

```bash
cd /srv/nginx-journey/gauntlet/black-friday/lab
./warroom.sh board                 # the final score
./warroom.sh down                  # containers and network; edge/, lb/, logs/ and state/ stay
```

To play again, or play the other edition: `./warroom.sh init oss --force` (or `plus`), then `up`. Your edge files are replaced; copy them somewhere first if you want to keep them.

Then the [Gauntlet Quiz](../../quiz.html?sprint=6&day=3&pool=gauntlet), and if you're writing it up, the build notes in [`notes.md`](notes.md) have the surprises.
