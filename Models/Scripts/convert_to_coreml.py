#!/usr/bin/env python3
"""Convert the source checkpoints to Core ML packages on macOS."""
from pathlib import Path
import argparse


def convert_yolo(source: Path, output: Path) -> None:
    from ultralytics import YOLO
    model = YOLO(str(source))
    model.export(format="coreml", imgsz=256, nms=False, half=True, project=str(output.parent), name=output.stem)


def convert_segformer(output: Path) -> None:
    import coremltools as ct
    import torch
    from transformers import SegformerForSemanticSegmentation

    model = SegformerForSemanticSegmentation.from_pretrained("nvidia/segformer-b0-finetuned-ade-512-512").eval()
    example = torch.zeros((1, 3, 224, 224), dtype=torch.float32)
    traced = torch.jit.trace(model, example, strict=False)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="pixel_values", shape=example.shape)],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.iOS26,
    )
    mlmodel.save(str(output))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root
    convert_yolo(root / "Source" / "yolo11n-seg.pt", root / "CoreML" / "YOLO11nSeg.mlpackage")
    convert_segformer(root / "CoreML" / "SegFormerB0.mlpackage")
