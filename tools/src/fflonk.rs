use handlebars::Handlebars;
use serde_json::json;

use std::collections::HashMap;
use std::error::Error;

use lazy_static::lazy_static;
use serde_json::Value;

use crate::types::{CommitmentSlot, G2Elements};
use crate::utils::{convert_list_to_hexadecimal, create_hash_map, format_const, get_modexp_function};

lazy_static! {
    static ref G2_ELEMENTS: HashMap<&'static str, G2Elements> = create_hash_map(&[(
        "g2_elements",
        G2Elements {
            x1: "VK_G2_ELEMENT_{}_X1",
            x2: "VK_G2_ELEMENT_{}_X2",
            y1: "VK_G2_ELEMENT_{}_Y1",
            y2: "VK_G2_ELEMENT_{}_Y2",
        }
    ),]);
    static ref NON_RESIDUES: HashMap<&'static str, &'static str> =
        create_hash_map(&[("non_residues", "VK_NON_RESIDUES_{}"),]);
    static ref COMMITMENT: HashMap<&'static str, CommitmentSlot> =
        create_hash_map(&[(
            "c0",
            CommitmentSlot {
                x: "VK_C0_G1_X",
                y: "VK_C0_G1_Y"
            }
        ),]);
}

pub fn insert_residue_elements_and_commitments(
    template: &str,
    vk: &HashMap<String, Value>,
    vk_hash: &str,
    l2_mode: bool
) -> Result<String, Box<dyn Error>> {
    let reg = Handlebars::new();
    let residue_g2_elements = generate_residue_g2_elements(vk);
    let commitments = generate_commitments(vk);

    let modexp_function = get_modexp_function(l2_mode); 
    let verifier_contract_template = template.replace("{{modexp_function}}", &modexp_function);

    Ok(reg.render_template(
        &verifier_contract_template,
        &json!({"residue_g2_elements": residue_g2_elements, "c0": commitments,
                        "vk_hash": vk_hash}),
    )?)
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
                    .unwrap_or_else(|| panic!("{} value not found", xy))
                    .as_object()
                    .unwrap_or_else(|| panic!("{} value not an object", xy));

                let c_value = convert_list_to_hexadecimal(
                    field
                        .get(c)
                        .unwrap_or_else(|| panic!("{} value not found", c))
                        .as_array()
                        .unwrap_or_else(|| panic!("{} value not an array", c)),
                );
                format_const(&c_value, &slots[i].replace("{}", &idx.to_string()))
            })
        })
        .collect::<Vec<String>>()
        .join("")
}

fn generate_residue_g2_elements(vk: &HashMap<String, Value>) -> String {
    let mut residue_g2_elements = String::new();

    let vk_non_residues = vk.get("non_residues").unwrap().as_array().unwrap();
    residue_g2_elements.push_str("// k1 = 5, k2 = 7\n");
    residue_g2_elements.push_str(&extract_non_residues(
        vk_non_residues,
        NON_RESIDUES["non_residues"],
    ));

    let vk_g2_elements = vk.get("g2_elements").unwrap().as_array().unwrap();
    residue_g2_elements.push_str("\n    // G2 Elements = [1]_2, [s]_2\n");
    residue_g2_elements.push_str(&extract_g2_elements(
        vk_g2_elements,
        G2_ELEMENTS["g2_elements"],
    ));

    residue_g2_elements
}

fn generate_commitments(vk: &HashMap<String, Value>) -> String {
    let mut commitment = String::new();

    let c0 = vk.get("c0").unwrap();
    commitment.push_str("// [C0]1 = qL(X^8)+ X*qR(X^8)+ X^2*qO(X^8)+ X^3*qM(X^8)+ X^4*qC(X^8)+ X^5*Sσ1(X^8)+ X^6*Sσ2(X^8)+ X^7*Sσ3(X^8)\n");
    commitment.push_str(&extract_commitment_slots(
        &[c0.clone()],
        COMMITMENT["c0"],
    ));

    commitment
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
            let mstore_x = format_const(&x, &slot_tuple.x.replace("{}", &idx.to_string()));
            let y = convert_list_to_hexadecimal(y);
            let mstore_y = format_const(&y, &slot_tuple.y.replace("{}", &idx.to_string()));
            format!("{}{}", mstore_x, mstore_y)
        })
        .collect::<Vec<String>>()
        .join("")
}
