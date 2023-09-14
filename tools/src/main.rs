use std::collections::HashMap;
use std::error::Error;
use std::fs;
use std::fs::File;
use std::io::{BufReader, Write};

use lazy_static::lazy_static;
use serde_json::{from_reader, Value};
use structopt::StructOpt;

type CommitmentSlot = (&'static str, &'static str);
type G2Elements = (&'static str, &'static str, &'static str, &'static str);

fn create_hash_map<Type: Copy>(
    key_value_pairs: &[(&'static str, Type)],
) -> HashMap<&'static str, Type> {
    let mut hash_map = HashMap::new();
    for &(key, value) in key_value_pairs {
        hash_map.insert(key, value);
    }
    hash_map
}

lazy_static! {
    static ref COMMITMENTS_SLOTS: HashMap<&'static str, CommitmentSlot> = create_hash_map(&[
        (
            "gate_setup_commitments",
            ("VK_GATE_SETUP_{}_X_SLOT", "VK_GATE_SETUP_{}_Y_SLOT")
        ),
        (
            "gate_selectors_commitments",
            ("VK_GATE_SELECTORS_{}_X_SLOT", "VK_GATE_SELECTORS_{}_Y_SLOT")
        ),
        (
            "permutation_commitments",
            ("VK_PERMUTATION_{}_X_SLOT", "VK_PERMUTATION_{}_Y_SLOT")
        ),
        (
            "lookup_tables_commitments",
            ("VK_LOOKUP_TABLE_{}_X_SLOT", "VK_LOOKUP_TABLE_{}_Y_SLOT")
        ),
    ]);
    static ref INDIVIDUAL_COMMITMENTS: HashMap<&'static str, CommitmentSlot> = create_hash_map(&[
        (
            "lookup_selector_commitment",
            ("VK_LOOKUP_SELECTOR_X_SLOT", "VK_LOOKUP_SELECTOR_Y_SLOT")
        ),
        (
            "lookup_table_type_commitment",
            ("VK_LOOKUP_TABLE_TYPE_X_SLOT", "VK_LOOKUP_TABLE_TYPE_Y_SLOT")
        ),
    ]);
    static ref G2_ELEMENTS: HashMap<&'static str, G2Elements> = create_hash_map(&[(
        "g2_elements",
        (
            "VK_G2_ELEMENTS_{}_X1",
            "VK_G2_ELEMENTS_{}_X2",
            "VK_G2_ELEMENTS_{}_Y1",
            "VK_G2_ELEMENTS_{}_Y2",
        )
    ),]);
    static ref NON_RESIDUES: HashMap<&'static str, &'static str> =
        create_hash_map(&[("non_residues", "VK_NON_RESIDUES_{}_SLOT"),]);
}

#[derive(Debug, StructOpt)]
#[structopt(
    name = "zksync_verifier_contract_generator",
    about = "Tool for generating verifier contract using scheduler json key"
)]
struct Opt {
    /// Input path to scheduler verification key file.
    #[structopt(
        short = "i",
        long = "input_path",
        default_value = "data/scheduler_key.json"
    )]
    input_path: String,

    /// Output path to verifier contract file.
    #[structopt(short = "o", long = "output_path", default_value = "data/Verifier.sol")]
    output_path: String,
}

fn main() -> Result<(), Box<dyn Error>> {
    let opt = Opt::from_args();

    let reader = BufReader::new(File::open(&opt.input_path)?);

    let vk: HashMap<String, Value> = from_reader(reader)?;

    let verifier_contract_template = fs::read_to_string("data/verifier_contract_template.txt")?;

    let verifier_contract_template =
        insert_residue_elements_and_commitments(&verifier_contract_template, &vk)?;

    let mut file = File::create(opt.output_path)?;

    file.write_all(verifier_contract_template.as_bytes())?;
    Ok(())
}

fn insert_residue_elements_and_commitments(
    template: &str,
    vk: &HashMap<String, Value>,
) -> Result<String, Box<dyn Error>> {
    let residue_g2_elements = generate_residue_g2_elements(&vk);
    let verifier_contract_template =
        template.replace("{residue_g2_elements}", &residue_g2_elements);

    let commitments = generate_commitments(&vk);
    let verifier_contract_template =
        verifier_contract_template.replace("{commitments}", &commitments);

    Ok(verifier_contract_template)
}

fn format_mstore(hex_value: &str, slot: &str) -> String {
    format!("            mstore({}, 0x{})\n", slot, hex_value)
}

fn format_const(hex_value: &str, slot_name: &str) -> String {
    let hex_value = hex_value.trim_start_matches('0');
    let hex_value_formatted = format!("{:0>2}", hex_value);
    format!(
        "    uint256 internal constant {} = 0x{};\n",
        slot_name, hex_value_formatted
    )
}

fn convert_list_to_hexadecimal(numbers: &Vec<Value>) -> String {
    numbers
        .iter()
        .map(|v| format!("{:01$x}", v.as_u64().expect("Failed to parse as u64"), 16))
        .rev()
        .collect::<String>()
}

fn extract_commitment_slots(items: &[Value], slot_tuple: (&str, &str)) -> String {
    items
        .iter()
        .enumerate()
        .filter_map(|(idx, item)| {
            if let Value::Object(map) = item {
                if let (Some(Value::Array(x)), Some(Value::Array(y))) = (map.get("x"), map.get("y"))
                {
                    let x = convert_list_to_hexadecimal(x);
                    let mstore_x = format_mstore(&x, &slot_tuple.0.replace("{}", &idx.to_string()));
                    let y = convert_list_to_hexadecimal(y);
                    let mstore_y = format_mstore(&y, &slot_tuple.1.replace("{}", &idx.to_string()));
                    Some(format!("{}{}", mstore_x, mstore_y))
                } else {
                    None
                }
            } else {
                None
            }
        })
        .collect::<Vec<String>>()
        .join("")
}

fn extract_non_residues(items: &[Value], slot_name: &str) -> String {
    items
        .iter()
        .enumerate()
        .map(|(idx, item)| {
            let hex_value = convert_list_to_hexadecimal(
                item.as_array().expect("Failed to parse item as array"),
            );
            format_const(&hex_value, &slot_name.replace("{}", &idx.to_string()))
        })
        .collect::<Vec<String>>()
        .join("")
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

fn extract_g2_elements(elements: &[Value], slot_tuple: (&str, &str, &str, &str)) -> String {
    let slots: [&str; 4] = [slot_tuple.0, slot_tuple.1, slot_tuple.2, slot_tuple.3];
    let xy_pairs = [("x", "c0"), ("x", "c1"), ("y", "c0"), ("y", "c1")];

    elements
        .iter()
        .enumerate()
        .flat_map(|(idx, element)| {
            xy_pairs.iter().enumerate().map(move |(i, &(xy, c))| {
                let field = element
                    .get(xy)
                    .expect(&format!("{} value not found", xy))
                    .as_object()
                    .expect(&format!("{} value not an object", xy));

                let c_value = convert_list_to_hexadecimal(
                    field
                        .get(c)
                        .expect(&format!("{} value not found", c))
                        .as_array()
                        .expect(&format!("{} value not an array", c)),
                );
                format_const(&c_value, &slots[i].replace("{}", &idx.to_string()))
            })
        })
        .collect::<Vec<String>>()
        .join("")
}

fn generate_commitments(vk: &HashMap<String, Value>) -> String {
    let commitments_data = [
        ("gate_setup_commitments", "gate setup commitments"),
        ("gate_selectors_commitments", "gate selectors commitments"),
        ("permutation_commitments", "permutation commitments"),
        ("lookup_tables_commitments", "lookup tables commitments"),
    ];

    let individual_commitments_data = [
        ("lookup_selector_commitment", "lookup selector commitment"),
        ("lookup_table_type_commitment", "table type commitment"),
    ];

    let commitments = commitments_data
        .iter()
        .filter_map(|(key, comment)| {
            vk.get(*key).and_then(|value| {
                if let Value::Array(data) = value {
                    Some(format!(
                        "\n            // {}\n{}",
                        comment,
                        extract_commitment_slots(data, COMMITMENTS_SLOTS[*key])
                    ))
                } else {
                    None
                }
            })
        })
        .collect::<Vec<String>>()
        .join("");

    let individual_commitments = individual_commitments_data
        .iter()
        .filter_map(|(key, comment)| {
            vk.get(*key).map(|value| {
                format!(
                    "\n            // {}\n{}",
                    comment,
                    extract_individual_commitments(value, INDIVIDUAL_COMMITMENTS[*key],)
                )
            })
        })
        .collect::<Vec<String>>()
        .join("");

    format!("{}{}", commitments, individual_commitments)
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
