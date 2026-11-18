"""Generate stexx dev-seed profile photos locally with DreamShaper 8 (CreativeML OpenRAIL-M) on MPS."""
# Usage: pip install torch diffusers transformers accelerate safetensors pillow
#        python scripts/generate-seed-photos.py specs.json src/dev/seed-photos
# Runs on Apple Silicon (MPS). Model: Lykon/dreamshaper-8 (CreativeML OpenRAIL-M). Outputs are people who do not exist.
import json, os, sys, time
import torch
from diffusers import StableDiffusionPipeline, DPMSolverMultistepScheduler

specs = json.load(open(sys.argv[1]))
out_dir = sys.argv[2]
os.makedirs(out_dir, exist_ok=True)
pipe = StableDiffusionPipeline.from_pretrained(
    "Lykon/dreamshaper-8", torch_dtype=torch.float16, use_safetensors=True, variant="fp16",
    safety_checker=None, requires_safety_checker=False,
)
pipe.scheduler = DPMSolverMultistepScheduler.from_config(pipe.scheduler.config, algorithm_type="dpmsolver++", use_karras_sigmas=True)
pipe = pipe.to("mps")
pipe.enable_attention_slicing()
NEG = ("nsfw, nude, naked, shirtless, underwear, cleavage, child, teen, minor, young boy, cartoon, anime, 3d render, "
       "deformed, disfigured, extra fingers, bad hands, bad anatomy, blurry, lowres, watermark, text, logo, frame")
for i, s in enumerate(specs):
    path = os.path.join(out_dir, s["file"])
    if os.path.exists(path):
        continue
    t = time.time()
    g = torch.Generator("cpu").manual_seed(s["seed"])
    img = pipe(s["prompt"], negative_prompt=NEG, width=512, height=640, num_inference_steps=28,
               guidance_scale=6.0, generator=g).images[0]
    img.save(path, quality=90)
    print(f"{i+1}/{len(specs)} {s['file']} {time.time()-t:.1f}s", flush=True)
print("DONE", flush=True)
