Generate videos with automatic scene chaining (start+end frame transitions).

Usage: `/fk-gen-chain-videos <project_id> <video_id>`

This creates smooth transitions between scenes in a chain by using the **NEXT scene's image as the endImage** of the current scene's video, so the last frame of scene N matches the first frame of scene N+1 → seamless concat.

## Before you start: chaining runs on Omni, not Veo

On `flow.google.com` the two model families differ:

| Project `video_model_family` | What a scene with an end frame gets |
|---|---|
| `omni_flash` | **Real chaining** — Omni First+Last (`nprQif`, `omni_flash_i2v_8s_first_last`). Live-verified 2026-09-24: the seam between chained clips matched at SSIM 0.96 |
| `veo` (default) | `UNSUPPORTED_ON_BATCH_API`, terminal — Veo's end-image slot was never captured. With `FLOW_ALLOW_DEGRADED=1` it renders plain i2v off the start frame instead, and the seam is **not** seamless |

So check the project first and switch it to Omni if needed:

```bash
curl -s http://127.0.0.1:8100/api/projects/<PID> | python3 -c "import sys,json; print(json.load(sys.stdin)['video_model_family'])"

curl -s -X PATCH http://127.0.0.1:8100/api/projects/<PID> \
  -H "Content-Type: application/json" -d '{"video_model_family": "omni_flash"}'
```

Omni costs about 25 credits per 8s clip. If the user wants to stay on Veo, say
plainly that the result will not be seamless and offer a crossfade in concat
instead (`/fk-concat-fit-narrator`). Restoring Veo chaining needs a payload
capture — `docs/CAPTURE.md`.

## How chaining works

For any scene that has a CHILD in the chain (i.e. some other scene with `parent_scene_id == this.id`):

```
Scene N (chain head or middle): startImage = sceneN.image, endImage = sceneN+1.image
                                → video plays FROM sceneN.image TO sceneN+1.image (the next scene's image)

Scene N+1 (next in chain):      startImage = sceneN+1.image, endImage = sceneN+2.image (if N+2 exists)
                                → continues the chain

Last scene in chain (no child): startImage = lastScene.image, NO endImage
                                → plain frame_2_video, no chained transition
```

**Key invariant**: at the cut between two consecutive chain scenes, `sceneN.video.last_frame == sceneN+1.image == sceneN+1.video.first_frame` → **concat is seamless**.

The `endImage` is the **CHILD scene's image** (the next scene's image_media_id), NOT the parent's. Chain heads (ROOT scenes that have a child) DO need an endImage; only chain tails (last scene in chain) and standalone ROOT scenes leave `endImage` null.

## Step 1: Pre-check

```bash
# All scene images must be ready with UUID media_ids
curl -s "http://127.0.0.1:8100/api/scenes?video_id=<VID>"
```

ABORT if any scene is missing `${ori}_image_media_id` (UUID).

## Step 2: Set up end_scene_media_ids for chaining

For each scene that has a CHILD in the chain (i.e. some other scene's `parent_scene_id == this.id`), set its `${ori}_end_scene_media_id` to that **child** scene's `${ori}_image_media_id`:

```bash
curl -X PATCH http://127.0.0.1:8100/api/scenes/<SID> \
  -H "Content-Type: application/json" \
  -d '{"${ori}_end_scene_media_id": "<child_scene_image_media_id>"}'
```

Logic:
1. Sort scenes by `display_order`
2. Build a child map: `parent_id -> child_scene` (scan all scenes, key by `parent_scene_id`)
3. For each scene `S`:
   - If `S` has a child in the map → set `${ori}_end_scene_media_id = child.${ori}_image_media_id`
   - Else (no child = chain tail or standalone ROOT) → leave `${ori}_end_scene_media_id` null

**Affected scenes** (those that need an `end_scene_media_id`): chain heads (ROOT-with-child) AND chain middles (CONTINUATION-with-child). NOT chain tails, NOT standalone ROOTs.

**Write a `transition_prompt` for every scene that gets an end frame.** The
worker sends `transition_prompt` instead of `video_prompt` whenever the scene
has an end frame, and the model has to get from this image to the child's in
one clip — so describe that motion, in the same `0-3s / 3-6s / 6-8s` beats and
with the same `Audio:` line as `video_prompt`:

```bash
curl -X PATCH http://127.0.0.1:8100/api/scenes/<SID> \
  -H "Content-Type: application/json" \
  -d '{"transition_prompt": "0-3s: <start pose>. 3-6s: <the move>. 6-8s: <arrive at the child image pose>. ... Audio: ..."}'
```

Without one the worker falls back to `video_prompt`, which describes this
scene only, and the clip lurches toward the end frame in the last second.

**Common mistake**: setting `end_scene_media_id` to the PARENT's image. That makes scene N's video end at scene N-1's frame — when concatenated forward (N then N+1), the cut between N's last frame and N+1's first frame is hard, defeating the chain. The correct frame at the end of scene N's video is `sceneN+1.image`.

## Step 3: Submit ALL video requests at once

The server handles throttling automatically (max 5 concurrent, 10s cooldown). The worker reads `${ori}_end_scene_media_id` from each scene (set in Step 2) and passes it as the end frame. On an `omni_flash` project that is Omni First+Last; the chain tail (no end frame) gets Omni first frame. A scene whose video is already `COMPLETED` is skipped — reset its `${ori}_video_status` to `PENDING` first to re-render it as a chain link.

```bash
curl -X POST http://127.0.0.1:8100/api/requests/batch \
  -H "Content-Type: application/json" \
  -d '{
    "requests": [
      {"type": "GENERATE_VIDEO", "scene_id": "<SID1>", "project_id": "<PID>", "video_id": "<VID>", "orientation": "${ORI}"},
      {"type": "GENERATE_VIDEO", "scene_id": "<SID2>", "project_id": "<PID>", "video_id": "<VID>", "orientation": "${ORI}"}
    ]
  }'
```

Build the `requests` array from ALL scenes in display_order. Do NOT manually batch or loop.

Poll aggregate status every 30s until done:

```bash
curl -s "http://127.0.0.1:8100/api/requests/batch-status?video_id=<VID>&type=GENERATE_VIDEO"
# Wait for: "done": true
# If "all_succeeded": false → some failed, check individual failures
```

## Known Limitation: Concat Gap

**Problem:** When concatenating chained videos, the endImage frames of scene N overlap with the startImage frames of scene N+1 — both are the same image. On the old Veo path this produced **10-16 static/duplicate frames (~0.4-0.7s)** at each cut point. Omni First+Last is much tighter — about **4 frames (~0.17s)** at the head of the next clip in the 2026-09-24 run. Measure rather than guess:

```bash
ffmpeg -i <next_scene>.mp4 -vf freezedetect=n=0.003:d=0.15 -map 0:v -f null - 2>&1 | grep freeze_
```

```
Scene 1 video: [action...] [endImage = scene2 still] ← 10-16 frames
Scene 2 video: [startImage = scene2 still] [action...] ← 10-16 frames
Concat result:  ...action → [~0.8-1.4s static gap] → action...
```

**Mitigations:**
- **Trim overlap** — use `trim_start` / `trim_end` on scenes to cut the static frames before concat. Typically trim 0.4-0.7s from the end of scene N and/or the start of scene N+1.
- **Don't overuse chaining** — only chain scenes that truly need smooth visual continuity (same location, continuous action). For scene changes (new location, time jump), use ROOT without endImage — a hard cut is more natural.
- **Mix techniques** — alternate between chained (CONTINUATION) and unchained (ROOT) scenes. Hard cuts between different locations feel intentional; gaps between continuous action feel broken.

**When to chain vs not:**

| Situation | Recommendation |
|-----------|---------------|
| Same location, continuous action | CONTINUATION (chain) |
| Location change, time jump | ROOT (hard cut, or a ~0.5s crossfade in concat to show time passing) |
| Dramatic moment, reaction shot | INSERT (hard cut — intentional) |
| Dream/flashback transition | ROOT or R2V (stylistic break) |

## Step 4: Output

Print table:
| Scene | Order | Chain | endImage from | video_status | Duration |
|-------|-------|-------|---------------|-------------|----------|

Print: "Chained videos ready. Run /fk-concat <VID> to merge."
Remind: "Check concat gaps — trim 0.4-0.7s overlap at chain boundaries if needed."
