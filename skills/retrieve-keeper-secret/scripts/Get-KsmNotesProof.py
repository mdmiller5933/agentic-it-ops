"""Print a no-value length/SHA proof for a KSM record's top-level notes."""

import argparse
import hashlib
import json

from keeper_secrets_manager_cli import KeeperCli


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", default="contoso")
    parser.add_argument("--uid", required=True)
    args = parser.parse_args()

    record = KeeperCli(profile_name=args.profile)._client.get_secrets([args.uid])[0]
    value = record.dict.get("notes", "")
    print(
        json.dumps(
            {
                "length": len(value),
                "sha": hashlib.sha256(value.encode("utf-8")).hexdigest()[:12].upper(),
            }
        )
    )


if __name__ == "__main__":
    main()
