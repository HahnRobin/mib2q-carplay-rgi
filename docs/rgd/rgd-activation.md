---
title: RGD activation & the visible_in_app authority
tags: [rgd, activation, ios-re, verified]
status: verified-decompile
sources:
  - code: java_patch/com/luka/carplay/rgd/RouteGuidance.java
  - code: hook/routeguidance/rgd_hook.c
  - code: java_patch/com/luka/carplay/core/ScreenModule.java
  - code: hook/routeguidance/rgd_tlv.h
  - firmware: accessoryd 23G71 +[ACCNavigationRouteGuidanceUpdateInfo keyForType:]
reconciles:
  - docs/reference/NAVSD_FCTID_MATRIX.md
  - docs/reference/IOS266_MANEUVER_DECOMPILE.md
  - docs/archive/MIB3.md
---

# RGD activation & the `visible_in_app` authority

How the patch decides that CarPlay route guidance is **active** (cluster shows the maneuver overlay)
versus **inactive** (return to the stock cluster).

## Context

Where this sits in the route-guidance path - **you are here** decides *active/inactive*; everything
upstream just delivers state, everything downstream renders it:

> [[rgd-tlv]] - parse TLVs -> [[bus-protocol]] - EVT_RGD_UPDATE -> **rgd-activation** - decide active ->
> [[bap-fctids]] - HUD + [[compositing]] - cluster overlay

```mermaid
flowchart LR
    ios["iOS RGD<br/>0x5200-0x5204"] --> tlv["hook: parse TLVs<br/>rgd-tlv"]
    tlv --> bus["bus: EVT_RGD_UPDATE<br/>bus-protocol"]
    bus --> act["decide wantActive<br/>+ BAP start / ctx 80"]:::here
    act --> bap["BAP FctIDs (HUD)<br/>bap-fctids"]
    act --> comp["cluster ctx 74<->80<br/>display-contexts"]
    classDef here fill:#fde68a,stroke:#b45309,color:#000;
```

## The decision

`RouteGuidance` recomputes `wantActive` on every activation-relevant delta from three iAP2 inputs:

| Input | iAP2 source | Meaning |
|---|---|---|
| `routeState` | RouteGuidanceState (TLV 0x01) | 0=NO_ROUTE ... 1=ROUTE_SET ... 5=REROUTING |
| `maneuverCount` / maneuver list | ManeuverCount (0x0E) / CurrentList (0x0D) | how many maneuvers are queued |
| `visible_in_app` | **RouteGuidanceBeingShownInApp** (0x0F) | is the nav app's guidance UI on screen |

```mermaid
flowchart TD
    A[activation delta] --> B{"visible_in_app known? (0/1)"}
    B -- "yes" --> C{"visible_in_app == 1?"}
    C -- "yes" --> W[wantActive = true]
    C -- "no" --> R{"route still looks active?<br/>routeState>=ROUTE_SET OR maneuvers>0"}
    R -- "yes" --> W
    R -- "no" --> X[wantActive = false]
    B -- "no (-1)" --> R2{"route looks active?"}
    R2 -- "yes" --> W
    R2 -- "no" --> X
    W --> G{"sourceSupportsRg==0<br/>or routeState==NO_ROUTE?"}
    X --> G
    G -- "yes" --> X2[force wantActive = false]
    G -- "no" --> K[keep wantActive]
```

## `visible_in_app` is a visibility flag, not a route-active flag

`visible_in_app` is iAP2 RouteGuidanceUpdate **TLV 0x0F** = Apple's
`ACCNav_RGUpdate_RouteGuidanceBeingShownInApp` (accessoryd 23G71,
`+[ACCNavigationRouteGuidanceUpdateInfo keyForType:]`, case 0xF). It reports whether the nav app's
guidance UI is currently **on screen** - a separate field from `RouteGuidanceState` (0x01),
`ManeuverCount` (0x0E) and `SourceSupportsRouteGuidance` (0x14). iOS sends it `0` for third-party maps
and whenever the nav app is not the foreground CarPlay app, **even mid-route**.

Therefore `visible_in_app==0` must **not** deactivate while the route still looks active; genuine
end-of-route is caught by the `routeState==NO_ROUTE_SET` hard override. See [[rgd-tlv]] for the full
TLV map and [[accessoryd-rgd]] for the enum evidence.

## Activation, presentation and route end

`wantActive` rising starts BAP and exposes ctx 80 on the **same edge**; renderer readiness no longer
gates the context:

```mermaid
stateDiagram-v2
    direction LR
    [*] --> Idle: stock ctx 74
    Idle --> Active: wantActive -> bap.onStart() ok -> setNavActive(true)
    Active --> Active: presentation lost (renderer not ready) - keep ctx 80, retry 500 ms
    Active --> Hold: wantActive false -> bap.onStop()/onRouteEnd(), setNavActive(false)
    Hold --> Idle: VC Fct44 KDK visible=false
    Hold --> Active: route active again
    note right of Active
        ctx 80 (maneuver over stock map);
        presentationConfirmed tracks
        renderer FRAME_READY + BAP publish
    end note
```

- **Start** - `bap.onStart()` publishes the BAP start sync; only if it succeeds does
  `ScreenModule.setNavActive(true)` select ctx 80. The BAP start is the edge on which the VC animates its
  KDK slot in, so waiting for `FRAME_READY` only left that slot empty. If the start fails, the cluster
  stays on stock and a presentation check retries.
- **Presentation** - `presentationConfirmed` still requires renderer `FRAME_READY` plus a successful
  BAP publish; it gates the route-text hold/scroll ([[vc-route-text]]) and triggers a full cached-state
  replay, not the context. A lost renderer keeps ctx 80 and retries on a 500 ms tick
  (`PRESENTATION_RETRY_MS`); dirty bits survive until both outputs have published.
- **End** - `setNavActive(false)` does not drop the context immediately: while the VC still reports the
  KDK visible, `ScreenModule` holds ctx 80 until the VC withdraws it (FctID 44 ->
  `ClusterLayerController.onVcVisibility` -> `ScreenModule.onVcKdkVisibility(false)`), then returns to
  stock 74. No timer is involved - see [[display-contexts]] / [[kdk-geometry]].
- **Route generation** - a changed `route_generation` from the hook (native route reset) clears all
  maneuver slots, lane events and route fields before the new fields apply, so reused slot versions never
  inherit the previous route. See [[rgd-tlv]].

## Transient `route_state=0` is debounced in the C hook

`hook/routeguidance/rgd_hook.c` holds a deferred flush for `route_state=0` so a momentary reset /
reroute never reaches Java as a deactivation - any deactivation Java sees is genuine
(`source_supports_rg=0`, `visible_in_app=0` with no route, or a real route end).

## Which navigation apps send route guidance

The app does not build the iAP2 `RouteGuidanceUpdate`: iOS `CarPlay.framework` serializes it from the
app's `CPNavigationSession`, and the on/off gate is `SourceSupportsRouteGuidance` (TLV `0x14`), set
only when the app's map delegate implements `mapTemplateShouldProvideNavigationMetadata:`. From the
decrypted IPAs (analysis carried over from mhi2-carplay `THIRD_PARTY_NAV_APPS.md`, not tested on the
car):

| App | Metadata gate | maneuverType | What reaches the cluster |
|---|---|---|---|
| Apple / Google Maps | implemented | set | full route guidance |
| AMap | implemented while navigating | never set | session, ETA and distance; maneuvers are typeless |
| Waze | never implemented, so `SourceSupportsRouteGuidance = 0` | never set | nothing: `RouteGuidance` deactivates on `source_supports_rg == 0` |

The payload carries no images - only semantics (type, junction shape, angles, distance, strings) -
which is why [[maneuver-mapping]] draws its own icons. Not fixable from the head unit.

## Open / to-verify

- (!) `routeState==5` (REROUTING) "accept all maneuvers" path is documented for MHI3 but not
  implemented here - decide if needed. See [[maps-maneuvers]].
