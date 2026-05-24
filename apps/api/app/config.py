from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[3]
TERRAFORM_DIR = ROOT_DIR / "infra" / "terraform"
DEFAULT_STATE = {
    "loadBalancer": {
        "name": "sre-playground-lb",
        "status": "idle",
    },
    "traffic": {
        "blue": 100,
        "green": 0,
    },
    "services": [
        {
            "id": "blue",
            "name": "sre-playground-blue",
            "status": "serving",
            "version": "blue",
        },
        {
            "id": "green",
            "name": "sre-playground-green",
            "status": "standby",
            "version": "green",
        },
    ],
}
