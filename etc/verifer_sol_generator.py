import argparse
import json
from typing import List, Tuple

COMMITMENTS_SLOTS = {
    "gate_setup_commitments": (
        "VK_GATE_SETUP_{}_X_SLOT",
        "VK_GATE_SETUP_{}_Y_SLOT"
    ),
    "gate_selectors_commitments": (
        "VK_GATE_SELECTORS_{}_X_SLOT",
        "VK_GATE_SELECTORS_{}_Y_SLOT"
    ),
    "permutation_commitments": (
        "VK_PERMUTATION_{}_X_SLOT",
        "VK_PERMUTATION_{}_Y_SLOT"
    ),
    "lookup_tables_commitments": (
        "VK_LOOKUP_TABLE_{}_X_SLOT",
        "VK_LOOKUP_TABLE_{}_Y_SLOT"
    ),
}

INDIVIDUAL_COMMITMENTS = {
    "lookup_selector_commitment": ("VK_LOOKUP_SELECTOR_X_SLOT", "VK_LOOKUP_SELECTOR_Y_SLOT"),
    "lookup_table_type_commitment": ("VK_LOOKUP_TABLE_TYPE_X_SLOT", "VK_LOOKUP_TABLE_TYPE_Y_SLOT"),
}

G2_ELEMENTS = {
    "g2_elements": (
        "VK_G2_ELEMENTS_{}_X1",
        "VK_G2_ELEMENTS_{}_X2",
        "VK_G2_ELEMENTS_{}_Y1",
        "VK_G2_ELEMENTS_{}_Y2"
    ),
}

NON_RESIDUES = {
    "non_residues": "VK_NON_RESIDUES_{}_SLOT"
}


def convert_list_to_hexadecimal(numbers):
    numbers = list(reversed(numbers))
    hex_str = ''.join(hex(num)[2:].zfill(16) for num in numbers)
    hex_value = hex(int(hex_str, 16))
    return hex_value


def format_mstore(hex_value: str, slot: str):
    return f'            mstore({slot}, {hex_value})\n'


def format_const(hex_value: str, slot_name: str):
    return f'    uint256 internal constant {slot_name} = {hex_value};\n'


def extract_commitment_slots(items: List[dict], slot_tuple: Tuple[str, str]):
    output = ""
    for idx, item in enumerate(items):
        x = convert_list_to_hexadecimal(item['x'])
        output += format_mstore(x, slot_tuple[0].format(idx))
        y = convert_list_to_hexadecimal(item['y'])
        output += format_mstore(y, slot_tuple[1].format(idx))
    return output


def extract_individual_commitments(item: dict, slot_tuple: Tuple[str, str]):
    output = ""
    x = convert_list_to_hexadecimal(item['x'])
    output += format_mstore(x, slot_tuple[0])
    y = convert_list_to_hexadecimal(item['y'])
    output += format_mstore(y, slot_tuple[1])
    return output


def extract_g2_elements(items: List[dict], slot_tuple: Tuple[str, str]):
    output = ""
    for idx, item in enumerate(items):
        x_c0 = convert_list_to_hexadecimal(item['x']['c0'])
        output += format_const(x_c0, slot_tuple[0].format(idx))
        x_c1 = convert_list_to_hexadecimal(item['x']['c1'])
        output += format_const(x_c1, slot_tuple[1].format(idx))
        y_c0 = convert_list_to_hexadecimal(item['y']['c0'])
        output += format_const(y_c0, slot_tuple[2].format(idx))
        y_c1 = convert_list_to_hexadecimal(item['y']['c1'])
        output += format_const(y_c1, slot_tuple[3].format(idx))
    return output


def extract_non_residues(items: List[dict], slot_name: str):
    output = ""
    for idx, item in enumerate(items):
        hex_value = convert_list_to_hexadecimal(item)
        output += format_const(hex_value, slot_name.format(idx))
    return output


def generate_commitments(vk: dict):
    commitments = ""

    commitments += '\n            // gate setup commitments\n'
    commitments += extract_commitment_slots(vk['gate_setup_commitments'], COMMITMENTS_SLOTS['gate_setup_commitments'])

    commitments += '\n            // gate selectors\n'
    commitments += extract_commitment_slots(vk['gate_selectors_commitments'],
                                            COMMITMENTS_SLOTS['gate_selectors_commitments'])

    commitments += '\n            // permutation\n'
    commitments += extract_commitment_slots(vk['permutation_commitments'], COMMITMENTS_SLOTS['permutation_commitments'])

    commitments += '\n            // lookup selector commitment\n'
    commitments += extract_individual_commitments(vk['lookup_selector_commitment'],
                                                  INDIVIDUAL_COMMITMENTS['lookup_selector_commitment'])

    commitments += '\n            // lookup table commitments\n'
    commitments += extract_commitment_slots(vk['lookup_tables_commitments'],
                                            COMMITMENTS_SLOTS['lookup_tables_commitments'])

    commitments += '\n            // table type commitment\n'
    commitments += extract_individual_commitments(vk['lookup_table_type_commitment'],
                                                  INDIVIDUAL_COMMITMENTS['lookup_table_type_commitment'])

    return commitments


def generate_residue_g2_elements(vk):
    residue_g2_elements = ""
    # Extract non residues
    residue_g2_elements += '\n    // non residues\n'
    residue_g2_elements += str(extract_non_residues(vk['non_residues'], NON_RESIDUES['non_residues']))
    # Extract g2 elements
    residue_g2_elements += '\n    // g2 elements\n'
    residue_g2_elements += str(extract_g2_elements(vk['g2_elements'], G2_ELEMENTS['g2_elements']))
    return residue_g2_elements


def read_file(filename: str):
    with open(filename) as vk:
        return json.load(vk)


def main():
    parser = argparse.ArgumentParser(description="Process a input file and output to another file")

    # Add arguments
    parser.add_argument('-i', '--input', type=str, help="Path of the input file")
    parser.add_argument('-o', '--output', type=str, help="Path of the output file")

    # Parse the arguments
    args = parser.parse_args()

    # assert that the arguments are not None
    assert args.input is not None, "Input file path must be provided"
    assert args.output is not None, "Output file path must be provided"

    print(f'reading verification key from path {args.input}')
    print(f'would be saving generated contract ar {args.output}')
    vk = read_file(args.input)

    # Load verifier_contract_template.txt
    with open('verifier_contract_template.txt', 'r') as file:
        verifier_contract_template = file.read()

    # Insert the residue_g2_elements into the verifier_contract_template
    residue_g2_elements = generate_residue_g2_elements(vk)
    verifier_contract_template = verifier_contract_template.replace('{residue_g2_elements}', residue_g2_elements)

    # Insert the commitments into the verifier_contract_template
    commitments = generate_commitments(vk)
    verifier_contract_template = verifier_contract_template.replace('{commitments}', commitments)

    with open(args.output, 'w') as file:
        file.write(verifier_contract_template)


if __name__ == '__main__':
    main()
