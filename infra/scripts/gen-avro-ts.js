#!/usr/bin/env node
/* Minimal Avro → TypeScript generator without external deps. */
const fs = require('fs');
const path = require('path');

const SCHEMA_DIR = process.env.SCHEMA_DIR || path.resolve(__dirname, '..', 'schemas');
const OUT_DIR = process.env.OUT_DIR || path.resolve(__dirname, '..', 'generated', 'ts');
const OUT_FILE = process.env.OUT_FILE || path.join(OUT_DIR, 'events.ts');

fs.mkdirSync(OUT_DIR, { recursive: true });

function readSchemas(dir) {
  return fs.readdirSync(dir)
    .filter(f => f.endsWith('.avsc'))
    .map(f => ({ file: f, schema: JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')) }));
}

function tsPrimitive(t) {
  switch (t) {
    case 'string': return 'string';
    case 'boolean': return 'boolean';
    case 'bytes': return 'Uint8Array';
    case 'int':
    case 'long':
    case 'float':
    case 'double': return 'number';
    case 'null': return 'null';
    default: return t; // named type reference
  }
}

function tsFromType(type, decls, parentName) {
  if (typeof type === 'string') {
    return tsPrimitive(type);
  }
  if (Array.isArray(type)) {
    // union
    const types = type.map(t => tsFromType(t, decls, parentName));
    return [...new Set(types)].join(' | ');
  }
  // object
  switch (type.type) {
    case 'enum': {
      const typeName = type.name || `${parentName}Enum`;
      // Emit const object and a derived union type
      const entries = type.symbols
        .map(s => `  ${s}: ${JSON.stringify(s)}`)
        .join(',\n');
      decls.push(
        `export const ${typeName} = {\n${entries}\n} as const;`,
        `export type ${typeName} = typeof ${typeName}[keyof typeof ${typeName}];`
      );
      return typeName;
    }
    case 'array': {
      const item = tsFromType(type.items, decls, parentName + 'Item');
      return `${item}[]`;
    }
    case 'map': {
      const v = tsFromType(type.values, decls, parentName + 'Value');
      return `Record<string, ${v}>`;
    }
    case 'record': {
      const rName = type.name || parentName;
      const fieldsTs = (type.fields || []).map(f => fieldToTs(f, decls, rName)).join('\n');
      decls.push(`export interface ${rName} {\n${fieldsTs}\n}`);
      return rName;
    }
    default: {
      return 'any';
    }
  }
}

function fieldToTs(field, decls, parentName) {
  // Optional if union includes null
  let t = field.type;
  let optional = false;
  if (Array.isArray(t)) {
    const hasNull = t.some(x => x === 'null' || (typeof x === 'object' && x.type === 'null'));
    if (hasNull) {
      optional = true;
      t = t.filter(x => !(x === 'null' || (typeof x === 'object' && x.type === 'null')));
      if (t.length === 1) t = t[0];
    }
  }
  const ts = tsFromType(t, decls, `${parentName}_${field.name}`);
  const doc = field.doc ? ` // ${field.doc}` : '';
  return `  ${field.name}${optional ? '?' : ''}: ${ts};${doc}`;
}

function generate(schemaObj) {
  const decls = [];
  const name = schemaObj.schema && schemaObj.schema.name ? schemaObj.schema.name : path.basename(schemaObj.file, '.avsc');
  const topTs = tsFromType(schemaObj.schema, decls, name);
  if (!decls.some(d => d.includes(`interface ${topTs}`) || d.includes(`type ${topTs} =`))) {
    // Ensure at least a top-level export exists
    decls.push(`export type ${name} = ${topTs};`);
  }
  const header = `// Generated from ${schemaObj.file}. Do not edit manually.\n`;
  return header + decls.join('\n\n') + '\n';
}

const schemas = readSchemas(SCHEMA_DIR);
const sections = schemas.map(s => {
  const ts = generate(s);
  const title = s.schema && s.schema.name ? s.schema.name : path.basename(s.file, '.avsc');
  return `// ===== ${title} (from ${s.file}) =====\n${ts}`;
});

const banner = `// Generated from Avro schemas in ${path.relative(process.cwd(), SCHEMA_DIR)}` +
  `\n// Single-file output: ${path.basename(OUT_FILE)}\n`;

fs.writeFileSync(OUT_FILE, `${banner}\n${sections.join('\n')}`, 'utf8');
console.log(`[OK] Wrote ${path.relative(process.cwd(), OUT_FILE)}`);
