# PRTS model assets

The initial local inference target uses two source models:

- `Source/yolo11n-seg.pt` is the source checkpoint for the obstacle instance segmenter.
- SegFormer-B0 is downloaded by the conversion script from its Hugging Face model identifier and is not copied into this repository because its source snapshot is large.

Before conversion, verify the source checkpoint hash against `Manifests/yolo11n-seg.json`. Generated Core ML packages are build artifacts and should be added only after conversion and numerical validation on the signed Mac environment.
