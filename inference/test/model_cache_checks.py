"""Artifact integrity and resume tests with synthetic bytes, not model timing."""
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from models.prepare import download, prepare, MODEL_ID, REQUIRED, verify_cache


class ModelCacheChecks(unittest.TestCase):
    def test_git_and_lfs_checksums_and_failed_partial_cleanup(self):
        payload = b"synthetic artifact for checksum validation"
        for lfs in (False, True):
            metadata = dict(size=len(payload), blobId=hashlib.sha1(f"blob {len(payload)}\0".encode()+payload).hexdigest())
            if lfs:
                metadata["lfs"] = dict(sha256=hashlib.sha256(payload).hexdigest())
            with tempfile.TemporaryDirectory() as temporary:
                target = Path(temporary)/"artifact"
                with patch("urllib.request.urlopen", return_value=io.BytesIO(payload)):
                    download("https://invalid.test/not-requested", target, metadata)
                self.assertEqual(target.read_bytes(), payload)
                target.unlink()
                with patch("urllib.request.urlopen", return_value=io.BytesIO(b"x"*len(payload))):
                    with self.assertRaisesRegex(ValueError, "checksum|SHA-256"):
                        download("https://invalid.test/not-requested", target, metadata)
                self.assertFalse(target.exists())
                self.assertFalse(target.with_name("artifact.part").exists())

    def test_interrupted_preparation_resumes_only_verified_files(self):
        config = json.dumps(dict(model_type="llama")).encode()
        payloads = {name: (config if name=="config.json" else b"TEST_ONLY_ARTIFACT_BYTES") for name in REQUIRED}
        siblings = [dict(rfilename=name,size=len(data),blobId=hashlib.sha1(f"blob {len(data)}\0".encode()+data).hexdigest()) for name,data in payloads.items()]
        metadata = dict(id=MODEL_ID,sha="a"*40,gated=False,private=False,siblings=siblings)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/"download-state.json").write_text(json.dumps(metadata))
            (root/"config.json").write_bytes(config)
            requested = []
            def response(url, **kwargs):
                name = url.rsplit("/",1)[-1]
                requested.append(name)
                return io.BytesIO(payloads[name])
            with patch("urllib.request.urlopen", side_effect=response):
                result = prepare(root,"main")
            self.assertNotIn("config.json",requested)
            self.assertEqual(set(requested),REQUIRED-{"config.json"})
            self.assertFalse((root/"download-state.json").exists())
            self.assertEqual(verify_cache(root),result)
            (root/"model.safetensors").write_bytes(b"corrupted")
            with self.assertRaisesRegex(ValueError,"checksum"):
                verify_cache(root)

    def test_unknown_files_are_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            marker=root/"user-data"
            marker.write_text("keep")
            with self.assertRaisesRegex(ValueError,"requires inspection"):
                prepare(root,"main")
            self.assertEqual(marker.read_text(),"keep")


if __name__ == "__main__":
    unittest.main()
