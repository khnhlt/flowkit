from typing import Literal

RequestType = Literal[
    "GENERATE_IMAGE", "REGENERATE_IMAGE", "EDIT_IMAGE",
    "GENERATE_VIDEO", "REGENERATE_VIDEO", "GENERATE_VIDEO_REFS", "UPSCALE_VIDEO",
    "GENERATE_CHARACTER_IMAGE", "REGENERATE_CHARACTER_IMAGE", "EDIT_CHARACTER_IMAGE",
]

Orientation = Literal["VERTICAL", "HORIZONTAL"]

StatusType = Literal["PENDING", "PROCESSING", "COMPLETED", "FAILED"]

ChainType = Literal["ROOT", "CONTINUATION", "INSERT"]

SceneSource = Literal["root", "user", "system"]

ProjectStatus = Literal["ACTIVE", "ARCHIVED", "DELETED"]

VideoStatus = Literal["DRAFT", "PROCESSING", "COMPLETED", "FAILED"]

PaygateTier = Literal["PAYGATE_TIER_ONE", "PAYGATE_TIER_TWO"]

# Which model family the worker uses for scene videos. "veo" keeps the
# tier-mapped Veo models; "omni_flash" routes i2v, chained and r2v videos to
# Omni 1.1 Flash (for plans without Veo access, and for the chaining/r2v modes
# the batch path has not ported for Veo).
VideoModelFamily = Literal["veo", "omni_flash"]

EntityType = Literal["character", "location", "creature", "visual_asset", "generic_troop", "faction"]
