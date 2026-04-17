import json

from web3 import Web3
from eth_account import Account


def generate_keystore(
    private_key_hex: str, password: str | None, file_path: str | None = None
) -> None:
    """Generate a JSON keystore file from a raw hex private key.

    Args:
        private_key_hex: The raw private key as a hex string (e.g., "0x...").
        password: The password to encrypt the private key.
        file_path: Optional file path to save the keystore JSON.
            If None, print to console.
    """
    # Ensure the private key is in bytes format
    private_key_bytes = Web3.to_bytes(hexstr=private_key_hex)

    # Encrypt the private key with the password
    keystore = Account.encrypt(private_key_bytes, password)

    # Save the keystore to a file
    if file_path:
        with open(file_path, "w") as f:
            json.dump(keystore, f, indent=4)
        print(f"Keystore saved to {file_path}")
    else:
        # Print the keystore to the console
        print("Keystore JSON:")
        print("========================================")
        print(json.dumps(keystore, indent=4))
        print("========================================")


if __name__ == "__main__":
    # Anvil Test Ethereum private key
    private_key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    password = ""  # Replace with your desired password

    generate_keystore(private_key, password)
