const docItemTypes = {
  contract: "ContractDefinition",
  enum: "EnumDefinition",
  error: "ErrorDefinition",
  event: "EventDefinition",
  function: "FunctionDefinition",
  modifier: "ModifierDefinition",
  struct: "StructDefinition",
  userDefinedValueType: "UserDefinedValueTypeDefinition",
  variable: "UserDefinedValueTypeDefinition"
};


module.exports = {
  gitbookAnchor(obj) {
    return "";
    const path = obj.__item_context.file.absolutePath;
    return path.toLowerCase().replace(/-+$/g, "").replace(/--+/g, "-");
  },
  filterByType(type, items) {
    return items.flatMap(item => {
      if (item.nodeType === docItemTypes[type]) {
        return item;
      }
      return (item.nodes || []).filter(node => node.nodeType === docItemTypes[type]);
    });
  },
  systemOnly(obj) {
    return obj.modifiers.some((modifier) => {
      return modifier.modifierName.name === "systemOnly";
    });
  },
  eq(paramKey, value) {
    return paramKey === value;
  },
  or(v1, v2) {
    return v1 || v2;
  }
};
