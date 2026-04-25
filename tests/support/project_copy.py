import shutil
import tempfile
from pathlib import Path


class FixtureProject:
    def __init__(self, fixture_root: Path) -> None:
        self.fixture_root = fixture_root.resolve()
        self._tempdir = None
        self.root = None

    def __enter__(self) -> Path:
        self._tempdir = tempfile.TemporaryDirectory(prefix="strider-fixture-")
        target = Path(self._tempdir.name) / self.fixture_root.name
        shutil.copytree(self.fixture_root, target)
        self.root = target
        return target

    def __exit__(self, exc_type, exc, tb) -> None:
        if self._tempdir is not None:
            self._tempdir.cleanup()
            self._tempdir = None
        self.root = None
