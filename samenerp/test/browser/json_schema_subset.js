"use strict";

// Dependency-free validation for the JSON Schema subset used by the browser
// artifact schemas: type, const, enum, required, properties,
// additionalProperties, pattern, minLength, maxLength, minimum, maximum, and
// array items.

function typeOf(value) {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  if (Number.isInteger(value)) return "integer";
  return typeof value;
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function matchesType(value, type) {
  switch (type) {
    case "null":
      return value === null;
    case "array":
      return Array.isArray(value);
    case "object":
      return isObject(value);
    case "integer":
      return Number.isInteger(value);
    case "number":
      return typeof value === "number" && Number.isFinite(value);
    case "string":
      return typeof value === "string";
    case "boolean":
      return typeof value === "boolean";
    default:
      return false;
  }
}

function validate(value, schema, jsonPath, errors) {
  if (!isObject(schema)) return;

  if (schema.type !== undefined) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!types.some((type) => matchesType(value, type))) {
      errors.push(`${jsonPath}: expected ${types.join(" or ")}, got ${typeOf(value)}`);
      return;
    }
  }

  if (Object.prototype.hasOwnProperty.call(schema, "const") && !Object.is(value, schema.const)) {
    errors.push(`${jsonPath}: expected constant ${JSON.stringify(schema.const)}`);
  }

  if (schema.enum && !schema.enum.some((option) => Object.is(option, value))) {
    errors.push(
      `${jsonPath}: expected one of ${schema.enum.map((option) => JSON.stringify(option)).join(", ")}`,
    );
  }

  if (typeof value === "string") {
    if (schema.minLength !== undefined && [...value].length < schema.minLength) {
      errors.push(`${jsonPath}: expected at least ${schema.minLength} characters`);
    }
    if (schema.maxLength !== undefined && [...value].length > schema.maxLength) {
      errors.push(`${jsonPath}: expected at most ${schema.maxLength} characters`);
    }
    if (schema.pattern !== undefined && !new RegExp(schema.pattern).test(value)) {
      errors.push(`${jsonPath}: does not match ${schema.pattern}`);
    }
  }

  if (typeof value === "number") {
    if (schema.minimum !== undefined && value < schema.minimum) {
      errors.push(`${jsonPath}: expected at least ${schema.minimum}`);
    }
    if (schema.maximum !== undefined && value > schema.maximum) {
      errors.push(`${jsonPath}: expected at most ${schema.maximum}`);
    }
  }

  if (Array.isArray(value) && schema.items !== undefined) {
    value.forEach((item, index) => {
      validate(item, schema.items, `${jsonPath}[${index}]`, errors);
    });
  }

  if (isObject(value)) {
    for (const key of schema.required || []) {
      if (!Object.prototype.hasOwnProperty.call(value, key)) {
        errors.push(`${jsonPath}: missing required property "${key}"`);
      }
    }

    for (const [key, childSchema] of Object.entries(schema.properties || {})) {
      if (Object.prototype.hasOwnProperty.call(value, key)) {
        validate(value[key], childSchema, `${jsonPath}.${key}`, errors);
      }
    }

    if (schema.additionalProperties === false) {
      const allowed = new Set(Object.keys(schema.properties || {}));
      for (const key of Object.keys(value)) {
        if (!allowed.has(key)) {
          errors.push(`${jsonPath}: unexpected property "${key}"`);
        }
      }
    }
  }
}

module.exports = { isObject, validate };
