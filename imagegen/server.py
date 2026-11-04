"""inkmud image service.

One endpoint the game server calls:

    POST /generate   {"prompt": str, "seed": int}   ->  image/png bytes
    GET  /health                                     ->  {"backend": ...}

The backend is chosen with IMAGE_BACKEND:

    local  SDXL-Turbo through diffusers on this machine's GPU (Apple MPS or
           CUDA). Development default.
    fal    FLUX.1 [schnell] on fal.ai (needs FAL_KEY). For a server without a
           GPU, such as a regular DigitalOcean droplet.

Requests are drawn one at a time.
"""

import io
import json
import os
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BACKEND = os.environ.get("IMAGE_BACKEND", "local")
PORT = int(os.environ.get("IMAGE_PORT", "7860"))
SIZE = int(os.environ.get("IMAGE_SIZE", "512"))
STEPS = int(os.environ.get("IMAGE_STEPS", "2"))

_lock = threading.Lock()


class LocalBackend:
    """SDXL-Turbo. ~2 s per 512px image at 2 steps on an M1 Pro."""

    def __init__(self):
        import torch
        from diffusers import AutoencoderKL, AutoPipelineForText2Image

        self.torch = torch
        if torch.backends.mps.is_available():
            self.device = "mps"
        elif torch.cuda.is_available():
            self.device = "cuda"
        else:
            self.device = "cpu"
        dtype = torch.float32 if self.device == "cpu" else torch.float16
        t = time.perf_counter()
        # The stock SDXL VAE produces black images in fp16; this one doesn't.
        vae = AutoencoderKL.from_pretrained("madebyollin/sdxl-vae-fp16-fix", torch_dtype=dtype)
        self.pipe = AutoPipelineForText2Image.from_pretrained(
            "stabilityai/sdxl-turbo",
            vae=vae,
            torch_dtype=dtype,
            variant="fp16",
        ).to(self.device)
        self.pipe.set_progress_bar_config(disable=True)
        print(f"[imagegen] SDXL-Turbo on {self.device}, loaded in {time.perf_counter() - t:.1f}s", flush=True)
        self.generate("a lantern", 0)  # warm-up

    def generate(self, prompt: str, seed: int) -> bytes:
        generator = self.torch.Generator("cpu").manual_seed(seed)
        image = self.pipe(
            prompt=prompt,
            num_inference_steps=STEPS,
            guidance_scale=0.0,
            width=SIZE,
            height=SIZE,
            generator=generator,
        ).images[0]
        buf = io.BytesIO()
        image.save(buf, format="PNG")
        return buf.getvalue()


class FalBackend:
    """FLUX.1 [schnell] on fal.ai. Untested until a FAL_KEY is configured."""

    URL = "https://fal.run/fal-ai/flux/schnell"

    def __init__(self):
        self.key = os.environ["FAL_KEY"]

    def generate(self, prompt: str, seed: int) -> bytes:
        body = json.dumps(
            {
                "prompt": prompt,
                "seed": seed,
                "image_size": {"width": SIZE, "height": SIZE},
                "num_inference_steps": 4,
                "enable_safety_checker": True,
            }
        ).encode()
        req = urllib.request.Request(
            self.URL,
            data=body,
            headers={"Authorization": f"Key {self.key}", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            result = json.load(resp)
        with urllib.request.urlopen(result["images"][0]["url"], timeout=60) as resp:
            data = resp.read()
        # fal returns JPEG by default; re-encode so the game always gets PNG.
        from PIL import Image

        buf = io.BytesIO()
        Image.open(io.BytesIO(data)).save(buf, format="PNG")
        return buf.getvalue()


backend = {"local": LocalBackend, "fal": FalBackend}[BACKEND]()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self._send(200, "application/json", json.dumps({"backend": BACKEND}).encode())
        else:
            self._send(404, "text/plain", b"not found")

    def do_POST(self):
        if self.path != "/generate":
            return self._send(404, "text/plain", b"not found")
        try:
            length = int(self.headers.get("content-length", "0"))
            payload = json.loads(self.rfile.read(length))
            prompt = str(payload["prompt"])[:1000]
            seed = int(payload.get("seed", 0))
        except Exception:
            return self._send(400, "text/plain", b"bad request")
        try:
            with _lock:
                t = time.perf_counter()
                png = backend.generate(prompt, seed)
                print(f"[imagegen] {time.perf_counter() - t:.1f}s seed={seed} {prompt[:80]}", flush=True)
        except Exception as e:  # report, don't crash the service
            print(f"[imagegen] failed: {e!r}", flush=True)
            return self._send(502, "text/plain", b"generation failed")
        self._send(200, "image/png", png)

    def _send(self, status, content_type, body):
        self.send_response(status)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"[imagegen] backend={BACKEND} listening on http://localhost:{PORT}", flush=True)
    ThreadingHTTPServer(("127.0.0.1" if BACKEND == "local" else "0.0.0.0", PORT), Handler).serve_forever()
