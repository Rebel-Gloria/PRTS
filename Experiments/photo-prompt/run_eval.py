"""受预算限制的三次独立重复测评。密钥只在内存中读取。"""

import argparse
import base64
import concurrent.futures as cf
import datetime
import hashlib
import json
import os
import random
import tempfile
import threading
import time
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
MODELS = ["wb/deepseek-v4.1-flash", "gpt-6-luna"]
ALLOWED = set(MODELS + ["hw/deepseek-v4.1-flash-1017"])
LOCK = threading.Lock()
LEDGER = ROOT / "runs/调用台账.jsonl"


def append(path, obj):
    with path.open("a") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")
        f.flush()
        os.fsync(f.fileno())


def reserve(meta):
    with LOCK:
        n = 0
        if LEDGER.exists():
            with LEDGER.open() as ledger:
                n = sum(1 for _ in ledger)
        if n >= 1500:
            raise RuntimeError("调用预算已经用完")
        append(
            LEDGER,
            {
                "序号": n + 1,
                "时间": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                **meta,
            },
        )
        return n + 1


def read_service(path):
    config = json.loads(path.read_text())
    endpoint = config["endpoint"]
    token = config["token"].strip()
    message = "评测配置需要 HTTPS 接口地址及其对应的密钥"
    try:
        parts = urlsplit(endpoint)
        port = parts.port
    except ValueError:
        # Parser errors can quote the supplied authority.
        raise ValueError(message) from None
    if (
        parts.scheme != "https"
        or not parts.hostname
        or parts.username is not None
        or parts.password is not None
        or parts.query
        or parts.fragment
        or not (port is None or 0 < port <= 65535)
        or not token
        or "\n" in token
        or "\r" in token
    ):
        raise ValueError(message)
    return endpoint, token


def service_fingerprint(endpoint):
    # The HTTPS host, effective port and exact API path identify the evaluator, not its key.
    parts = urlsplit(endpoint)
    identity = json.dumps(
        [parts.hostname, parts.port or 443, parts.path or "/"], separators=(",", ":")
    )
    return hashlib.sha256(identity.encode()).hexdigest()


def resume_round(path, summary, fingerprint):
    def check_source(record):
        if not isinstance(record, dict) or record.get("服务指纹") != fingerprint:
            raise ValueError

    done = set()
    models = set()
    try:
        if path.exists():
            with path.open() as rows:
                for line in rows:
                    row = json.loads(line)
                    check_source(row)
                    models.add(row["model"])
                    if row["成功"]:
                        done.add(row["id"])
        # Claim a fresh round/split before spending budget, without replacing any existing archive.
        try:
            with summary.open("x") as output:
                json.dump({"服务指纹": fingerprint}, output, ensure_ascii=False)
        except FileExistsError:
            saved = json.loads(summary.read_text())
            check_source(saved)
            return done, saved.get("模型") == sorted(models)
    except (KeyError, TypeError, ValueError):
        raise SystemExit(
            "无法确认本轮归档来自当前评测接口。请使用新轮次，原归档不会更改。"
        ) from None
    return done, False


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request_chat(endpoint, token, body):
    request = urllib.request.Request(
        endpoint,
        json.dumps(body).encode(),
        {
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
            "User-Agent": "curl/8.7.1",
        },
    )
    with urllib.request.build_opener(NoRedirect()).open(request, timeout=90) as response:
        return json.load(response)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("round")
    p.add_argument(
        "--service-config", type=Path, required=True, help="评测专用的接口与密钥 JSON 文件"
    )
    p.add_argument("--split", choices=["调优", "留出"], default="调优")
    p.add_argument("--models", nargs="+", default=MODELS)
    a = p.parse_args()
    if not set(a.models) <= ALLOWED:
        raise ValueError("模型不在授权清单")
    if a.split == "留出" and not (ROOT / "runs/最终冻结.json").exists():
        raise ValueError("必须先冻结最终提示词")
    (ROOT / "runs").mkdir(exist_ok=True)
    system = (ROOT / "prompts" / f"{a.round}.txt").read_text().strip()
    bench = json.loads((ROOT / "bench.json").read_text())
    endpoint, token = read_service(a.service_config)
    fingerprint = service_fingerprint(endpoint)
    path = ROOT / "runs" / f"{a.round}_{a.split}.jsonl"
    summary = path.with_name(path.stem + "_配置.json")
    done, summary_current = resume_round(path, summary, fingerprint)
    jobs = []
    for case in bench["cases"]:
        if case["split"] != a.split:
            continue
        for model in a.models:
            for task in case["tasks"]:
                for rep in range(1, 4):
                    ident = "|".join([a.round, a.split, model, case["id"], task["id"], str(rep)])
                    if ident not in done:
                        jobs.append((ident, case, model, task, rep))
    random.Random(20261029).shuffle(jobs)

    def call(j):
        ident, c, m, t, rep = j
        image = base64.b64encode((ROOT / c["image"]).read_bytes()).decode()
        body = {
            "model": m,
            "stream": False,
            "max_tokens": 300,
            "messages": [
                {"role": "system", "content": system},
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": t["text"]},
                        {
                            "type": "image_url",
                            "image_url": {"url": "data:image/jpeg;base64," + image},
                        },
                    ],
                },
            ],
        }
        if "deepseek" in m:
            body["thinking"] = {"type": "disabled"}
        meta = {
            "id": ident,
            "服务指纹": fingerprint,
            "轮次": a.round,
            "集合": a.split,
            "model": m,
            "图片": c["id"],
            "题目": t["id"],
            "重复": rep,
            "模式": t["mode"],
            "陷阱": t["trap"],
            "用户消息": t["text"],
            "系统提示词sha256": hashlib.sha256(system.encode()).hexdigest(),
            "图像sha256": c["preprocess"]["sha256"],
        }
        for attempt in range(1, 4):
            number = reserve({**meta, "尝试": attempt})
            start = time.monotonic()
            try:
                raw = request_chat(endpoint, token, body)
                choice = raw["choices"][0]
                answer = (choice["message"].get("content") or "").strip()
                if not answer:
                    raise ValueError("空回答")
                result = {
                    **meta,
                    "成功": True,
                    "调用序号": number,
                    "毫秒": round((time.monotonic() - start) * 1000),
                    "回答": answer,
                    "原始响应": raw,
                }
                with LOCK:
                    append(path, result)
                return True
            except Exception as e:
                error = {
                    "id": ident,
                    "调用序号": number,
                    "尝试": attempt,
                    "错误类型": type(e).__name__,
                    "状态码": getattr(e, "code", None),
                    "毫秒": round((time.monotonic() - start) * 1000),
                }
                with LOCK:
                    append(ROOT / "runs/调用失败.jsonl", error)
        result = {**meta, "成功": False, "回答": "", "错误": "三次尝试均失败"}
        with LOCK:
            append(path, result)
        return False

    print(f"{a.round} {a.split}：待测{len(jobs)}条，最多4并发", flush=True)
    if not jobs and summary_current:
        return
    with cf.ThreadPoolExecutor(max_workers=4) as ex:
        futures = [ex.submit(call, j) for j in jobs]
        ok = 0
        for i, f in enumerate(cf.as_completed(futures), 1):
            ok += f.result()
            if i % 20 == 0 or i == len(futures):
                print(f"完成 {i}/{len(jobs)}，成功 {ok}", flush=True)
    # Keep the source claim readable even if finalizing the summary is interrupted.
    with tempfile.TemporaryDirectory(dir=summary.parent) as temp:
        staged = Path(temp) / summary.name
        staged.write_text(
            json.dumps(
                {
                    "服务指纹": fingerprint,
                    "轮次": a.round,
                    "集合": a.split,
                    "模型": sorted(
                        {json.loads(line)["model"] for line in path.read_text().splitlines()}
                    )
                    if path.exists()
                    else [],
                    "重复次数": 3,
                    "最大并发": 4,
                    "最大输出token": 300,
                    "温度": "服务默认值，未传入",
                    "随机种子": "不传入；调度顺序固定20261029",
                    "DeepSeek思考": "disabled",
                    "User-Agent": "curl/8.7.1",
                    "系统提示词": system,
                    "备注": "基线留出结果在最终冻结之后采集；密钥和base64请求不落盘。",
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        staged.replace(summary)


if __name__ == "__main__":
    main()
