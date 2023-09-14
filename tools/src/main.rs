use std::collections::HashMap;
use std::fs;
use std::fs::File;
use std::io::{BufReader, Write};

use lazy_static::lazy_static;
use serde_json::{from_reader, Value};
use structopt::StructOpt;

type CommitmentSlot = (&'static str, &'static str);
type G2Elements = (&'static str, &'static str, &'static str, &'static str);

lazy_static! {
    static ref COMMITMENTS_SLOTS: HashMap<&'static str, CommitmentSlot> = {
        let mut m = HashMap::new();
        m.insert(
            "gate_setup_commitments",
            ("VK_GATE_SETUP_{}_X_SLOT", "VK_GATE_SETUP_{}_Y_SLOT"),
        );
        m.insert(
            "gate_selectors_commitments",
            ("VK_GATE_SELECTORS_{}_X_SLOT", "VK_GATE_SELECTORS_{}_Y_SLOT"),
        );
        m.insert(
            "permutation_commitments",
            ("VK_PERMUTATION_{}_X_SLOT", "VK_PERMUTATION_{}_Y_SLOT"),
        );
        m.insert(
            "lookup_tables_commitments",
            ("VK_LOOKUP_TABLE_{}_X_SLOT", "VK_LOOKUP_TABLE_{}_Y_SLOT"),
        );
        m
    };
    static ref INDIVIDUAL_COMMITMENTS: HashMap<&'static str, CommitmentSlot> = {
        let mut m = HashMap::new();
        m.insert(
            "lookup_selector_commitment",
            ("VK_LOOKUP_SELECTOR_X_SLOT", "VK_LOOKUP_SELECTOR_Y_SLOT"),
        );
        m.insert(
            "lookup_table_type_commitment",
            ("VK_LOOKUP_TABLE_TYPE_X_SLOT", "VK_LOOKUP_TABLE_TYPE_Y_SLOT"),
        );
        m
    };
    static ref G2_ELEMENTS: HashMap<&'static str, G2Elements> = {
        let mut m = HashMap::new();
        m.insert(
            "g2_elements",
            (
                "VK_G2_ELEMENTS_{}_X1",
                "VK_G2_ELEMENTS_{}_X2",
                "VK_G2_ELEMENTS_{}_Y1",
                "VK_G2_ELEMENTS_{}_Y2",
            ),
        );
        m
    };
    static ref NON_RESIDUES: HashMap<&'static str, &'static str> = {
        let mut m = HashMap::new();
        m.insert("non_residues", "VK_NON_RESIDUES_{}_SLOT");
        m
    };
}

#[derive(Debug, StructOpt)]
#[structopt(
name = "zksync_verifier_contract_generator",
about = "Tool for generating verifier contract using scheduler json key"
)]
struct Opt {
    /// Input path to scheduler verification key file.
    #[structopt(short = "i", long = "input_path", default_value = "data/scheduler_key.json")]
    input_path: String,

    /// Output path to verifier contract file.
    #[structopt(short = "o", long = "output_path", default_value = "data/Verifier.sol")]
    output_path: String,
}


fn main() {
    let opt = Opt::from_args();

    let reader = BufReader::new(File::open(&opt.input_path)
        .expect("Unable to open file"));

    let vk: HashMap<String, Value> = from_reader(reader)
        .expect("Unable to parse JSON");

    let verifier_contract_template = fs::read_to_string("data/verifier_contract_template.txt")
        .expect("Could not read verifier contract template");

    // Insert the residue_g2_elements into the verifier_contract_template
    let residue_g2_elements = generate_residue_g2_elements(&vk);
    let verifier_contract_template =
        verifier_contract_template.replace("{residue_g2_elements}", &residue_g2_elements);

    // Insert the commitments into the verifier_contract_template
    let commitments = generate_commitments(&vk);
    let verifier_contract_template =
        verifier_contract_template.replace("{commitments}", &commitments);

    // Open the output file
    let mut file = File::create(opt.output_path)
        .expect("Could not create output file");

    // Write the create verifier.sol contract to the file
    file.write_all(verifier_contract_template.as_bytes())
        .expect("Could not write to output file");
}

fn format_mstore(hex_value: &str, slot: &str) -> String {
    format!("            mstore({}, 0x{})\n", slot, hex_value)
}

fn format_const(hex_value: &str, slot_name: &str) -> String {
    format!(
        "    uint256 internal constant {} = 0x{};\n",
        slot_name, hex_value
    )
}

fn extract_commitment_slots(items: &[Value], slot_tuple: (&str, &str)) -> String {
    let mut output = String::new();
    for (idx, item) in items.iter().enumerate() {
        if let Value::Object(map) = item {
            if let (Some(Value::Array(x)), Some(Value::Array(y))) = (map.get("x"), map.get("y")) {
                let x = convert_list_to_hexadecimal(x);
                output.push_str(&format_mstore(
                    &x,
                    &slot_tuple.0.replace("{}", &idx.to_string()),
                ));
                let y = convert_list_to_hexadecimal(y);
                output.push_str(&format_mstore(
                    &y,
                    &slot_tuple.1.replace("{}", &idx.to_string()),
                ));
            }
        }
    }
    output
}

fn extract_individual_commitments(item: &Value, slot_tuple: (&str, &str)) -> String {
    let x = convert_list_to_hexadecimal(
        item.get("x")
            .expect("x value not found")
            .as_array()
            .expect("x value not an array"),
    );
    let mut output = format_mstore(&x, slot_tuple.0);

    let y = convert_list_to_hexadecimal(
        item.get("y")
            .expect("y value not found")
            .as_array()
            .expect("y value not an array"),
    );
    output.push_str(&format_mstore(&y, slot_tuple.1));

    output
}

fn convert_list_to_hexadecimal(numbers: &Vec<Value>) -> String {
    numbers
        .iter()
        .map(|v| format!("{:01$x}", v.as_u64().expect("Failed to parse as u64"), 16))
        .rev()
        .collect::<String>()
}

fn extract_g2_elements(elements: &[Value], slot_tuple: (&str, &str, &str, &str)) -> String {
    let mut output = vec![];
    for (idx, element) in elements.iter().enumerate() {
        let x = element
            .get("x")
            .expect("x value not found")
            .as_object()
            .expect("x value not an object");
        let y = element
            .get("y")
            .expect("y value not found")
            .as_object()
            .expect("y value not an object");

        let x_c0 = convert_list_to_hexadecimal(
            x.get("c0")
                .expect("c0 value not found")
                .as_array()
                .expect("c0 value not an array"),
        );
        let x_c1 = convert_list_to_hexadecimal(
            x.get("c1")
                .expect("c1 value not found")
                .as_array()
                .expect("c1 value not an array"),
        );
        let y_c0 = convert_list_to_hexadecimal(
            y.get("c0")
                .expect("c0 value not found")
                .as_array()
                .expect("c0 value not an array"),
        );
        let y_c1 = convert_list_to_hexadecimal(
            y.get("c1")
                .expect("c1 value not found")
                .as_array()
                .expect("c1 value not an array"),
        );

        output.push(format_const(
            &x_c0,
            &slot_tuple.0.replace("{}", &idx.to_string()),
        ));
        output.push(format_const(
            &x_c1,
            &slot_tuple.1.replace("{}", &idx.to_string()),
        ));
        output.push(format_const(
            &y_c0,
            &slot_tuple.2.replace("{}", &idx.to_string()),
        ));
        output.push(format_const(
            &y_c1,
            &slot_tuple.3.replace("{}", &idx.to_string()),
        ));
    }
    output.join("")
}

fn extract_non_residues(items: &[Value], slot_name: &str) -> String {
    let mut output = vec![];
    for (idx, item) in items.iter().enumerate() {
        let hex_value = convert_list_to_hexadecimal(item.as_array().expect("Failed to parse item as array"));
        output.push(format_const(
            &hex_value,
            &slot_name.replace("{}", &idx.to_string()),
        ));
    }
    output.join("")
}

fn generate_commitments(vk: &HashMap<String, Value>) -> String {
    let mut commitments = String::new();

    if let Some(Value::Array(vk_gate_setup_commitments)) = vk.get("gate_setup_commitments") {
        commitments.push_str("\n            // gate setup commitments\n");
        commitments.push_str(&extract_commitment_slots(
            vk_gate_setup_commitments,
            COMMITMENTS_SLOTS["gate_setup_commitments"],
        ));
    }

    if let Some(Value::Array(vk_gate_selectors_commitments)) = vk.get("gate_selectors_commitments")
    {
        commitments.push_str("\n            // gate selectors commitments\n");
        commitments.push_str(&extract_commitment_slots(
            vk_gate_selectors_commitments,
            COMMITMENTS_SLOTS["gate_selectors_commitments"],
        ));
    }

    if let Some(Value::Array(vk_permutation_commitments)) = vk.get("permutation_commitments") {
        commitments.push_str("\n            // permutation commitments\n");
        commitments.push_str(&extract_commitment_slots(
            vk_permutation_commitments,
            COMMITMENTS_SLOTS["permutation_commitments"],
        ));
    }

    if let Some(vk_lookup_selector_commitment) = vk.get("lookup_selector_commitment") {
        commitments.push_str("\n            // lookup selector commitment\n");
        commitments.push_str(&extract_individual_commitments(
            vk_lookup_selector_commitment,
            INDIVIDUAL_COMMITMENTS["lookup_selector_commitment"],
        ));
    }

    if let Some(Value::Array(vk_lookup_tables_commitments)) = vk.get("lookup_tables_commitments") {
        commitments.push_str("\n            // lookup tables commitments\n");
        commitments.push_str(&extract_commitment_slots(
            vk_lookup_tables_commitments,
            COMMITMENTS_SLOTS["lookup_tables_commitments"],
        ));
    }

    if let Some(vk_lookup_table_type_commitment) = vk.get("lookup_table_type_commitment") {
        commitments.push_str("\n            // table type commitment\n");
        commitments.push_str(&extract_individual_commitments(
            vk_lookup_table_type_commitment,
            INDIVIDUAL_COMMITMENTS["lookup_table_type_commitment"],
        ));
    }

    commitments
}

fn generate_residue_g2_elements(vk: &HashMap<String, Value>) -> String {
    let mut residue_g2_elements = String::new();

    if let Some(Value::Array(vk_non_residues)) = vk.get("non_residues") {
        residue_g2_elements.push_str("\n    // non residues\n");
        residue_g2_elements.push_str(&extract_non_residues(
            vk_non_residues,
            NON_RESIDUES["non_residues"],
        ));
    }

    if let Some(Value::Array(vk_g2_elements)) = vk.get("g2_elements") {
        residue_g2_elements.push_str("\n    // g2 elements\n");
        residue_g2_elements.push_str(&extract_g2_elements(
            vk_g2_elements,
            G2_ELEMENTS["g2_elements"],
        ));
    }

    residue_g2_elements
}
