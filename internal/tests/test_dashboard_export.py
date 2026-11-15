"""Portable V2 export checks; no Grafana connection required."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
EXPORTER = ROOT / "internal/grafana-exporter"


def objects(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from objects(child)


class DashboardExportTests(unittest.TestCase):
    def transform(self, resource):
        result = subprocess.run(
            ["jq", "-f", str(EXPORTER / "external-export.jq")],
            input=json.dumps(resource), text=True, capture_output=True, check=True,
        )
        return json.loads(result.stdout)

    def test_repository_dashboards(self):
        for path in (ROOT / "dashboards/src/en").glob("*.json"):
            with self.subTest(path=path.name):
                source = json.loads(path.read_text())
                exported = self.transform(source)
                self.assertEqual(exported["metadata"], {"name": source["metadata"]["name"]})
                references = [o for o in objects(source["spec"])
                              if o.get("kind") == "DataQuery"
                              and o.get("group") not in ("grafana", "__expr__")
                              and o.get("datasource", {}).get("name", "")
                              and not o["datasource"]["name"].startswith("$")]
                labels = [o["labels"]["grafana.app/export-label"]
                          for o in objects(exported["spec"])
                          if "grafana.app/export-label" in o.get("labels", {})]
                self.assertTrue(labels)
                self.assertEqual(len(labels), len(references))
                self.assertEqual(len(set(labels)), len({(o["group"], o["datasource"]["name"])
                                                      for o in references}))
                for o in objects(exported["spec"]):
                    if "grafana.app/export-label" in o.get("labels", {}):
                        self.assertNotIn("datasource", o)

    def test_distinct_sources_variables_and_builtins(self):
        refs = [{"kind": "DataQuery", "group": "prometheus", "datasource": {"name": uid},
                 "spec": {"expr": "up"}, "labels": {"keep": "value"}}
                for uid in ("one", "two", "one", "$source")]
        refs.append({"kind": "DataQuery", "group": "__expr__", "datasource": {"name": "__expr__"}})
        result = self.transform({"kind": "Dashboard", "apiVersion": "dashboard.grafana.app/v2",
                                 "metadata": {"name": "test"}, "spec": {"refs": refs}})["spec"]["refs"]
        self.assertEqual(result[0]["labels"], result[2]["labels"])
        self.assertNotEqual(result[0]["labels"], result[1]["labels"])
        self.assertEqual(result[0]["spec"], refs[0]["spec"])
        self.assertEqual(result[3:], refs[3:])

    def test_failure_preserves_output_and_continues(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            curl = folder / "curl"
            curl.write_text('#!/bin/sh\nprintf "%s\\n" "invalid json"\n')
            curl.chmod(0o755)
            config = folder / "test.env"
            config.write_text('declare -A DASHBOARDS=([one]="one.json" [two]="two.json")\n')
            (folder / "one.json").write_text("original")
            import os
            env = dict(os.environ, ENV_FILE=str(config), OUTPUT_DIR=directory,
                       PATH=directory + os.pathsep + os.environ["PATH"])
            result = subprocess.run(["bash", str(EXPORTER / "export-dashboards.sh")],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("Failed: 2", result.stdout)
            self.assertEqual((folder / "one.json").read_text(), "original")
            self.assertFalse(list(folder.glob("*.json.*")))


if __name__ == "__main__":
    unittest.main()
