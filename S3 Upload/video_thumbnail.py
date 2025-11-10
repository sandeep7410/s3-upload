import cv2
import numpy as np
from PIL import Image, ImageOps
import subprocess
import os, sys
import glob
import shutil
import mimetypes
import boto3
from tqdm import tqdm
import PySimpleGUI as sg
import tkinter as tk
from tkinter import filedialog, messagebox, scrolledtext
import threading, time


class RedirectText:
    def __init__(self, text_widget):
        self.output = text_widget

    def write(self, string):
        self.output.insert(tk.END, string)
        self.output.see(tk.END)
        self.output.update()

    def flush(self):
        pass

# =======================
# S3 Listing Functions
# =======================
def get_s3_session():
    """Get boto3 session with profile"""
    return boto3.Session(profile_name="nasa-personal")

def list_s3_buckets():
    """List all S3 buckets"""
    try:
        session = get_s3_session()
        s3 = session.client("s3")
        response = s3.list_buckets()
        buckets = [bucket["Name"] for bucket in response.get("Buckets", [])]
        return buckets
    except Exception as e:
        print(f"Error listing buckets: {e}")
        return []

def list_s3_objects(bucket_name, prefix=""):
    """List objects in an S3 bucket with optional prefix"""
    try:
        session = get_s3_session()
        s3 = session.client("s3")
        
        objects = []
        common_prefixes = []
        
        paginator = s3.get_paginator("list_objects_v2")
        page_iterator = paginator.paginate(Bucket=bucket_name, Prefix=prefix, Delimiter="/")
        
        for page in page_iterator:
            # Get objects (files)
            if "Contents" in page:
                for obj in page["Contents"]:
                    key = obj["Key"]
                    # Skip the prefix itself if it's a "directory"
                    if key != prefix:
                        objects.append({
                            "key": key,
                            "name": key[len(prefix):] if prefix else key,
                            "size": obj["Size"],
                            "is_folder": False
                        })
            
            # Get common prefixes (folders)
            if "CommonPrefixes" in page:
                for prefix_obj in page["CommonPrefixes"]:
                    prefix_path = prefix_obj["Prefix"]
                    folder_name = prefix_path[len(prefix):].rstrip("/") if prefix else prefix_path.rstrip("/")
                    common_prefixes.append({
                        "key": prefix_path,
                        "name": folder_name,
                        "is_folder": True
                    })
        
        # Combine and sort: folders first, then files
        result = sorted(common_prefixes, key=lambda x: x["name"]) + sorted(objects, key=lambda x: x["name"])
        return result
    except Exception as e:
        print(f"Error listing objects: {e}")
        return []

# =======================
# Upload file to S3 with progress bar (context manager)
# =======================
def upload_file_to_s3(local_path, bucket, s3_key, storage_class="STANDARD"):
    session = boto3.Session(profile_name="nasa-personal")
    s3 = session.client("s3")
    filesize = os.path.getsize(local_path)

    content_type, _ = mimetypes.guess_type(local_path)
    if content_type is None:
        content_type = "application/octet-stream"  # fallback

    print(f"☁️ Uploading {local_path} to s3://{bucket}/{s3_key} ({storage_class})")


    with tqdm(total=filesize, unit="B", unit_scale=True, desc=os.path.basename(local_path)) as pbar:
        s3.upload_file(
            Filename=local_path,
            Bucket=bucket,
            Key=s3_key,
            ExtraArgs={
                "StorageClass": storage_class,
                "ContentType": content_type
            },
            Callback=lambda bytes_transferred: pbar.update(bytes_transferred),
        )

    print(f"✅ Upload complete: s3://{bucket}/{s3_key}\n")



# =======================
# Upload any file (video or non-video)
# =======================
def process_file_and_upload(local_file_path, bucket_name, s3_key, thumbnail_suffix="_thumbnail.jpg", thumbnail_mode='timeframe'):
    """
    Uploads a file to S3. If it's a video, generates and uploads a thumbnail too.
    
    Args:
        local_file_path (str): Path to local file.
        bucket_name (str): Target S3 bucket.
        s3_key (str): Full S3 key/path for the file.
        thumbnail_suffix (str): Suffix for thumbnail file name (only for videos).
        thumbnail_mode (str): 'timeframe' or 'scenechange' for thumbnail generation (only for videos).
    """
    # Check if file is a video
    video_extensions = {'.mp4', '.avi', '.mov', '.mkv', '.wmv', '.flv', '.webm', '.m4v', '.3gp', '.ogv'}
    file_ext = os.path.splitext(local_file_path)[1].lower()
    is_video = file_ext in video_extensions
    
    if is_video:
        # Process video with thumbnail
        process_video_and_upload(local_file_path, bucket_name, s3_key, thumbnail_suffix, thumbnail_mode)
    else:
        # Upload non-video file directly
        print(f"📄 Uploading file: {local_file_path}")
        print(f"☁️  S3 destination: s3://{bucket_name}/{s3_key}")
        upload_file_to_s3(local_file_path, bucket_name, s3_key, storage_class="STANDARD")
        print("✅ Upload complete!")

# =======================
# Full video workflow
# =======================
def process_video_and_upload(local_video_path, bucket_name, s3_video_key, thumbnail_suffix="_thumbnail.jpg", thumbnail_mode='timeframe'):
    """
    Uploads a video and its thumbnail to S3.

    Args:
        local_video_path (str): Path to local video file.
        bucket_name (str): Target S3 bucket.
        s3_video_key (str): Full S3 key/path for the video.
        thumbnail_suffix (str): Suffix for thumbnail file name.
        thumbnail_mode (str): 'timeframe' or 'scenechange' for thumbnail generation.
    """
    # 1️⃣ Generate thumbnail locally
    print(f"📌 Generating 4x4 16:9 thumbnail for video: {local_video_path}")
    gen = VideoThumbnailGenerator(local_video_path, rows=4, cols=4, thumb_size=(320, 180))
    gen.create_thumbnail(mode=thumbnail_mode, scene_threshold=0.1)
    local_thumbnail_path = gen.output_path
    print(f"📌 Thumbnail saved at: {local_thumbnail_path}")

    # 2️⃣ Compute S3 key for thumbnail
    name, ext = os.path.splitext(os.path.basename(s3_video_key))
    s3_thumb_key = os.path.join(os.path.dirname(s3_video_key), f"{name}{thumbnail_suffix}")

    # 3️⃣ Upload video to Deep Archive
    upload_file_to_s3(local_video_path, bucket_name, s3_video_key, storage_class="DEEP_ARCHIVE")

    # 4️⃣ Upload thumbnail to Standard storage
    upload_file_to_s3(local_thumbnail_path, bucket_name, s3_thumb_key, storage_class="STANDARD")



class VideoThumbnailGenerator:
    def __init__(
        self,
        video_path,
        output_path=None,  # optional, will default to video folder + video_name_thumbnail.jpg
        rows=4,
        cols=4,
        thumb_size=(320, 180),
        temp_dir="thumbnails_temp",
    ):
        self.video_path = video_path
        self.rows = rows
        self.cols = cols
        self.thumb_width, self.thumb_height = thumb_size
        self.temp_dir = temp_dir
        os.makedirs(self.temp_dir, exist_ok=True)

        # Auto-generate output_path if not provided
        if output_path is None:
            folder = os.path.dirname(os.path.abspath(video_path))
            base_name = os.path.splitext(os.path.basename(video_path))[0]
            self.output_path = os.path.join(folder, f"{base_name}_thumbnail.jpg")
        else:
            self.output_path = output_path
    # ========================
    # Main entry point
    # ========================
    def create_thumbnail(self, mode="timeframe", scene_threshold=0.3, cleanup=True):
        print(f"📌 Starting thumbnail creation in mode: {mode}")
        if mode == "timeframe":
            self._create_timeframe_grid()
        elif mode == "scenechange":
            self._create_scenechange_grid_auto(scene_threshold)
        else:
            raise ValueError("Invalid mode. Use 'timeframe' or 'scenechange'.")

        if cleanup:
            self._cleanup_temp_dir()

    # ========================
    # 1️⃣ Timeframe-based mode
    # ========================
    def _create_timeframe_grid(self):
        print("⏱ Extracting frames based on evenly spaced time intervals...")
        cap = cv2.VideoCapture(self.video_path)
        if not cap.isOpened():
            raise ValueError("Cannot open video file")

        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        print(f"🎞 Total frames in video: {total_frames}")
        num_thumbnails = self.rows * self.cols
        frame_indices = np.linspace(0, total_frames - 1, num_thumbnails, dtype=int)
        print(f"🔢 Picking {num_thumbnails} frames at indices: {frame_indices}")

        frames = []
        for idx in frame_indices:
            cap.set(cv2.CAP_PROP_POS_FRAMES, idx)
            ret, frame = cap.read()
            if ret:
                frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                frames.append(Image.fromarray(frame))
        cap.release()

        print(f"✅ Extracted {len(frames)} frames for the grid")
        self._build_grid(frames)
        print(f"✅ Timeframe-based thumbnail grid saved to {self.output_path}")

    # ========================
    # 2️⃣ Scene-change-based mode (auto retry + fallback)
    # ========================
    def _create_scenechange_grid_auto(self, start_threshold=0.3):
        print("🎬 Extracting scene-change frames with auto-threshold...")
        num_thumbnails = self.rows * self.cols
        thresholds = [start_threshold, 0.15, 0.08, 0.05, 0.02]

        for t in thresholds:
            print(f"🔍 Trying scene detection with threshold={t}...")
            frame_files = self._extract_scenechange_frames(t)
            if frame_files:
                print(f"✅ Found {len(frame_files)} scene-change frames")
                selected_files = frame_files[:num_thumbnails]
                frames = [Image.open(f) for f in selected_files]
                self._build_grid(frames)
                print(f"✅ Scene-change thumbnail grid saved using threshold={t}")
                return
            else:
                print(f"⚠️ No frames found for threshold={t}")

        # If no frames found after all thresholds, fallback
        print("⚠️ No scene-change frames found after all thresholds. Falling back to timeframe mode...")
        self._create_timeframe_grid()

    def _extract_scenechange_frames(self, threshold):
        # Clean previous temp frames
        for f in glob.glob(os.path.join(self.temp_dir, "scene_*.jpg")):
            os.remove(f)

        output_pattern = os.path.join(self.temp_dir, "scene_%03d.jpg")

        ffmpeg_cmd = [
            "ffmpeg",
            "-i", self.video_path,
            "-vf", f"select=gt(scene\\,{threshold}),showinfo",
            "-vsync", "vfr",
            output_pattern,
            "-hide_banner",
            "-loglevel",
            "error",
        ]

        print(f"⚡ Running FFmpeg command for scene detection...")
        subprocess.run(ffmpeg_cmd, check=False)

        frame_files = sorted(glob.glob(os.path.join(self.temp_dir, "scene_*.jpg")))
        print(f"🖼 Number of frames extracted: {len(frame_files)}")
        return frame_files

    # ========================
    # 🧩 Helper: build grid in 16:9
    # ========================
    def _build_grid(self, frames):
        print("🖌 Building 16:9 thumbnail grid...")
        total_frames = len(frames)
        rows, cols = self.rows, self.cols
        aspect_ratio = 16 / 9
        grid_width = self.thumb_width * cols
        grid_height = int(grid_width / aspect_ratio)
        cell_width = grid_width // cols
        cell_height = grid_height // rows

        print(f"📏 Grid size: {grid_width}x{grid_height} (cells {cell_width}x{cell_height})")
        resized = [ImageOps.fit(f, (cell_width, cell_height), method=Image.LANCZOS) for f in frames]

        grid_image = Image.new("RGB", (grid_width, grid_height), color=(0, 0, 0))  # black background

        for i, f in enumerate(resized):
            r, c = divmod(i, cols)
            x, y = c * cell_width, r * cell_height
            grid_image.paste(f, (x, y))

        grid_image.save(self.output_path)
        print(f"✅ Saved grid to {self.output_path}")

    # ========================
    # 🧹 Cleanup
    # ========================
    def _cleanup_temp_dir(self):
        try:
            shutil.rmtree(self.temp_dir)
            print(f"🧹 Cleaned up temporary folder: {self.temp_dir}")
        except Exception as e:
            print(f"⚠️ Could not remove temp dir: {e}")

# =======================
# Command-line interface
# =======================
if __name__ == "__main__":
    if len(sys.argv) >= 3:
        # Command-line mode: python script.py <file_path> <s3_path>
        # s3_path format: "bucket/key" or "bucket/folder/" (if folder, filename will be appended)
        file_path = sys.argv[1]
        s3_path = sys.argv[2]
        
        # Parse bucket and key from s3_path
        if "/" in s3_path:
            bucket_name, s3_key = s3_path.split("/", 1)
        else:
            bucket_name = s3_path
            s3_key = ""
        
        # If s3_key ends with "/" (it's a folder), append the filename
        if s3_key.endswith("/"):
            filename = os.path.basename(file_path)
            s3_key = os.path.join(s3_key, filename).replace("\\", "/")
        
        try:
            print(f"📁 Processing file: {file_path}")
            print(f"☁️  S3 destination: s3://{bucket_name}/{s3_key}")
            process_file_and_upload(file_path, bucket_name, s3_key)
            print("✅ Processing complete!")
        except Exception as e:
            print(f"❌ Error: {e}")
            import traceback
            traceback.print_exc()
            sys.exit(1)
    elif len(sys.argv) == 2:
        # Only video path provided, but S3 path is required
        print("❌ Error: S3 path is required. Usage: python script.py <video_path> <s3_path>")
        sys.exit(1)
    else:
        # GUI mode (original tkinter interface)
        def select_file():
            filepath = filedialog.askopenfilename(filetypes=[("MP4 files", "*.mp4")])
            if filepath:
                entry_file.delete(0, tk.END)
                entry_file.insert(0, filepath)

        def upload_file():
            video_path = entry_file.get()
            s3_key = entry_s3.get()
            if not s3_key or not video_path:
                messagebox.showerror("Error", "Fill S3 Key and video file path")
                return
            # Call your Python workflow
            def task():
                try:
                    process_video_and_upload(video_path, "sandeep-nallapati", s3_key)
                except Exception as e:
                    print(f"❌ Error: {e}")
            threading.Thread(target=task, daemon=True).start()

        root = tk.Tk()
        root.title("Video Uploader")

        # File selection
        tk.Label(root, text="Video File").pack()
        frame_file = tk.Frame(root)
        entry_file = tk.Entry(frame_file, width=50)
        entry_file.pack(side=tk.LEFT)
        tk.Button(frame_file, text="Browse", command=select_file).pack(side=tk.LEFT, padx=5)
        frame_file.pack(pady=5)

        # S3 key
        tk.Label(root, text="S3 Key").pack()
        entry_s3 = tk.Entry(root, width=50)
        entry_s3.pack(pady=5)
        # Log output
        tk.Label(root, text="Logs:").pack()
        txt_log = scrolledtext.ScrolledText(root, width=80, height=20)
        txt_log.pack(pady=5)

        # Redirect stdout to the text widget
        sys.stdout = RedirectText(txt_log)

        # Upload button
        tk.Button(root, text="Upload Video", command=upload_file).pack(pady=10)

        root.mainloop()

"""
layout = [
    [sg.Text("Select a video file:")],
    [sg.Input(key="-FILE-"), sg.FileBrowse(file_types=(("MP4 Files", "*.mp4"),))],
    [sg.Text("S3 Key:"), sg.Input(key="-S3KEY-")],
    [sg.Output(size=(80, 20))],
    [sg.Button("Upload"), sg.Button("Exit")]
]

window = sg.Window("Video Uploader", layout)

while True:
    event, values = window.read()
    if event == sg.WINDOW_CLOSED or event == "Exit":
        break
    if event == "Upload":
        video_path = values["-FILE-"]
        s3_key = values["-S3KEY-"]
        if video_path and s3_key:
            process_video_and_upload(video_path, "sandeep-nallapati", s3_key)
        else:
            print("Please fill all fields")

window.close()

"""

"""
gen = VideoThumbnailGenerator("/Users/onsite/Desktop/20250228_184933.mp4", "time_grid.jpg")
gen.create_thumbnail(mode="timeframe")


gen = VideoThumbnailGenerator("/Users/onsite/Desktop/20250228_184933.mp4", "scene_grid.jpg")
gen.create_thumbnail(mode="scene_change", scene_threshold=0.1)


gen = VideoThumbnailGenerator("/Users/onsite/Movies/GX019090.MP4", "scene_grid.jpg")
gen.create_thumbnail(mode="scene_change", scene_threshold=0.1)

gen = VideoThumbnailGenerator("/Users/onsite/Movies/GX019090.MP4", "scene_grid.jpg")
gen.create_thumbnail(mode="scene_change", scene_threshold=0.1, cleanup=False)


gen = VideoThumbnailGenerator("/Users/onsite/Movies/GX019090.MP4", "scene_grid.jpg")
gen.create_thumbnail(mode="scene_change", scene_threshold=0.3)


gen = VideoThumbnailGenerator("/Users/onsite/Movies/GX019090.MP4", "time_grid.jpg")
gen.create_thumbnail(mode="timeframe")



gen = VideoThumbnailGenerator("/Users/onsite/Movies/GX019090.MP4")
gen.create_thumbnail(mode="scenechange", scene_threshold=0.3)

gen = VideoThumbnailGenerator("/Users/onsite/Movies/GX019090.MP4")
gen.create_thumbnail(mode="timeframe")

video_file = "videos/example.mp4"
s3_bucket = "my-videos-bucket"  # same bucket for video and thumbnail

process_video_and_upload(video_file, s3_bucket)


local_file = "/Users/onsite/Movies/pink pasta with panda.mp4"
bucket = "sandeep-nallapati"
s3_video_path = "gallery/sandeep-yagna-random/pink pasta with panda.mp4"  # S3 path you choose
process_video_and_upload(local_file, bucket, s3_video_path)

local_file='/Users/onsite/desktop/sample.mp4'
bucket = "sandeep-nallapati"
s3_video_path = "gallery/sandeep-yagna-random/sample.mp4"
process_video_and_upload(local_file, bucket, s3_video_path)


1. multiple file types support
2. multiple files upload support
3. cancel file upload
4. drag and drop
5. electron/ any other framework based desktop app

"""