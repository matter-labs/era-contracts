import argparse
import os
import shutil
import re
from pathlib import Path
import json

def load_system_config(system_config_path):
    """Loads environment variables from a .json file."""
    with open(system_config_path, "r") as file:
        env_variables = json.load(file)
    return env_variables


def copy_files(source_dir, destination_dir):
    """Copies all files from source_dir to destination_dir."""
    if not os.path.exists(destination_dir):
        os.makedirs(destination_dir)
    for item in os.listdir(source_dir):
        s = os.path.join(source_dir, item)
        d = os.path.join(destination_dir, item)
        if os.path.isdir(s):
            shutil.copytree(s, d, dirs_exist_ok=True)
        else:
            shutil.copy2(s, d)


def replace_env_variables_in_sol_files(directory, env_variables):
    """Replaces $(VARIABLE) with the corresponding environment variable value in .sol files."""
    for file_path in Path(directory).rglob("*.sol"):
        with open(file_path, "r") as file:
            content = file.read()

        modified_content = content
        for var in re.findall(r"\$\(([^)]+)\)", content):
            if var in env_variables:
                modified_content = modified_content.replace(
                    f"$({var})", str(env_variables[var])
                )
            else:
                raise Exception(f"Environment variable {var} not found in .env file.")

        if modified_content != content:
            with open(file_path, "w") as file:
                file.write(modified_content)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        prog="Preprocess .sol",
        description="This program processes Solidity files by replacing environment variable placeholders with their corresponding values.",
    )
    parser.add_argument("source", help="Path to solidity files source folder")
    parser.add_argument("--config", help="Path to system config file", required=True)
    parser.add_argument("--output", help="Path to output folder", required=True)

    args = parser.parse_args()

    # Load environment variables
    env_variables = load_system_config(args.config)

    # Copy files from source to destination
    copy_files(args.source, args.output)

    # Replace environment variable placeholders in Solidity files
    replace_env_variables_in_sol_files(args.output, env_variables)
