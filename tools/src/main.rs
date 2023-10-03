use handlebars::Handlebars;
use serde_json::json;
use std::collections::HashMap;
use std::error::Error;
use std::fs;
use std::fs::File;
use std::io::{BufReader, Write};

use lazy_static::lazy_static;
use serde_json::{from_reader, Value};
use structopt::StructOpt;

#[derive(Debug, Clone, Copy)]
struct CommitmentSlot {
    x: &'static str,
    y: &'static str,
}

#[derive(Debug, Clone, Copy)]
struct G2Elements {
    x1: &'static str,
    x2: &'static str,
    y1: &'static str,
    y2: &'static str,
}

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
            CommitmentSlot {
                x: "VK_GATE_SETUP_{}_X_SLOT",
                y: "VK_GATE_SETUP_{}_Y_SLOT"
            }
        ),
        (
            "gate_selectors_commitments",
            CommitmentSlot {
                x: "VK_GATE_SELECTORS_{}_X_SLOT",
                y: "VK_GATE_SELECTORS_{}_Y_SLOT"
            }
        ),
        (
            "permutation_commitments",
            CommitmentSlot {
                x: "VK_PERMUTATION_{}_X_SLOT",
                y: "VK_PERMUTATION_{}_Y_SLOT"
            }
        ),
        (
            "lookup_tables_commitments",
            CommitmentSlot {
                x: "VK_LOOKUP_TABLE_{}_X_SLOT",
                y: "VK_LOOKUP_TABLE_{}_Y_SLOT"
            }
        ),
    ]);
    static ref INDIVIDUAL_COMMITMENTS: HashMap<&'static str, CommitmentSlot> = create_hash_map(&[
        (
            "lookup_selector_commitment",
            CommitmentSlot {
                x: "VK_LOOKUP_SELECTOR_X_SLOT",
                y: "VK_LOOKUP_SELECTOR_Y_SLOT"
            }
        ),
        (
            "lookup_table_type_commitment",
            CommitmentSlot {
                x: "VK_LOOKUP_TABLE_TYPE_X_SLOT",
                y: "VK_LOOKUP_TABLE_TYPE_Y_SLOT"
            }
        ),
    ]);
    static ref G2_ELEMENTS: HashMap<&'static str, G2Elements> = create_hash_map(&[(
        "g2_elements",
        G2Elements {
            x1: "G2_ELEMENTS_{}_X1",
            x2: "G2_ELEMENTS_{}_X2",
            y1: "G2_ELEMENTS_{}_Y1",
            y2: "G2_ELEMENTS_{}_Y2",
        }
    ),]);
    static ref NON_RESIDUES: HashMap<&'static str, &'static str> =
        create_hash_map(&[("non_residues", "NON_RESIDUES_{}"),]);
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
    let reg = Handlebars::new();
    let residue_g2_elements = generate_residue_g2_elements(vk);
    let commitments = generate_commitments(vk);

    let verifier_contract_template =
        template.replace("{{residue_g2_elements}}", &residue_g2_elements);

    Ok(reg.render_template(
        &verifier_contract_template,
        &json!({"residue_g2_elements": residue_g2_elements,
                        "commitments": commitments}),
    )?)
}

fn format_mstore(hex_value: &str, slot: &str) -> String {
    format!("            mstore({}, 0x{})\n", slot, hex_value)
}

fn format_const(hex_value: &str, slot_name: &str) -> String {
    let hex_value = hex_value.trim_start_matches('0');
    let formatted_hex_value = if hex_value.len() < 64 && hex_value.len() >= 1 {
        format!("0{}", hex_value)
    } else {
        String::from(hex_value)
    };
    format!(
        "    uint256 internal constant {} = 0x{};\n",
        slot_name, formatted_hex_value
    )
}

fn convert_list_to_hexadecimal(numbers: &Vec<Value>) -> String {
    numbers
        .iter()
        .map(|v| format!("{:01$x}", v.as_u64().expect("Failed to parse as u64"), 16))
        .rev()
        .collect::<String>()
}

fn extract_commitment_slots(items: &[Value], slot_tuple: CommitmentSlot) -> String {
    items
        .iter()
        .enumerate()
        .map(|(idx, item)| {
            let map = item.as_object().unwrap();
            let x = map.get("x").unwrap().as_array().unwrap();
            let y = map.get("y").unwrap().as_array().unwrap();
            let x = convert_list_to_hexadecimal(x);
            let mstore_x = format_mstore(&x, &slot_tuple.x.replace("{}", &idx.to_string()));
            let y = convert_list_to_hexadecimal(y);
            let mstore_y = format_mstore(&y, &slot_tuple.y.replace("{}", &idx.to_string()));
            format!("{}{}", mstore_x, mstore_y)
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

fn extract_individual_commitments(item: &Value, commitment_slot: CommitmentSlot) -> String {
    let x = convert_list_to_hexadecimal(
        item.get("x")
            .expect("x value not found")
            .as_array()
            .expect("x value not an array"),
    );
    let mut output = format_mstore(&x, commitment_slot.x);

    let y = convert_list_to_hexadecimal(
        item.get("y")
            .expect("y value not found")
            .as_array()
            .expect("y value not an array"),
    );
    output.push_str(&format_mstore(&y, commitment_slot.y));

    output
}

fn extract_g2_elements(elements: &[Value], g2_elements: G2Elements) -> String {
    let slots: [&str; 4] = [
        g2_elements.x1,
        g2_elements.x2,
        g2_elements.y1,
        g2_elements.y2,
    ];
    let xy_pairs = [("x", "c1"), ("x", "c0"), ("y", "c1"), ("y", "c0")];

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
        .map(|(key, comment)| {
            let data = vk.get(*key).unwrap().as_array().unwrap();
            format!(
                "            // {}\n{}",
                comment,
                extract_commitment_slots(data, COMMITMENTS_SLOTS[*key])
            )
        })
        .collect::<Vec<String>>()
        .join("\n");

    let individual_commitments = individual_commitments_data
        .iter()
        .map(|(key, comment)| {
            format!(
                "\n            // {}\n{}",
                comment,
                extract_individual_commitments(vk.get(*key).unwrap(), INDIVIDUAL_COMMITMENTS[*key])
            )
        })
        .collect::<Vec<String>>()
        .join("");

    format!("{}{}", commitments, individual_commitments)
}

fn generate_residue_g2_elements(vk: &HashMap<String, Value>) -> String {
    let mut residue_g2_elements = String::new();

    let vk_non_residues = vk.get("non_residues").unwrap().as_array().unwrap();
    residue_g2_elements.push_str("// non residues\n");
    residue_g2_elements.push_str(&extract_non_residues(
        vk_non_residues,
        NON_RESIDUES["non_residues"],
    ));

    let vk_g2_elements = vk.get("g2_elements").unwrap().as_array().unwrap();
    residue_g2_elements.push_str("\n    // trusted setup g2 elements\n");
    residue_g2_elements.push_str(&extract_g2_elements(
        vk_g2_elements,
        G2_ELEMENTS["g2_elements"],
    ));

    residue_g2_elements
}
