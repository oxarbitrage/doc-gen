/-
Copyright (c) 2019 Robert Y. Lewis. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Robert Y. Lewis
-/

import tactic.core system.io data.string.defs tactic.interactive data.list.sort data.list.defs

/-!
Used to generate a json file for html docs.

The json file is a list of maps, where each map has the structure
```typescript
interface DeclInfo {
  name: string;
  args: efmt[];
  type: efmt;
  doc_string: string;
  filename: string;
  line: int;
  attributes: string[];
  equations: efmt[];
  kind: string;
  structure_fields: [string, efmt][];
  constructors: [string, efmt][];
}
```

Where efmt is defined as follows ('c' is a concatenation, 'n' is nesting):
```typescript
type efmt = ['c', efmt, efmt] | ['n', efmt] | string;
```

Include this file somewhere in mathlib, e.g. in the `scripts` directory. Make sure mathlib is
precompiled, with `all.lean` generated by `mk_all.sh`.

Usage: `lean entrypoint.lean` prints the generated JSON to stdout.
`entrypoint.lean` imports this file.
-/

open tactic io io.fs native

set_option pp.generalized_field_notation true

meta def string.is_whitespace (s : string) : bool :=
s.fold tt (λ a b, a && b.is_whitespace)

meta def string.has_whitespace (s : string) : bool :=
s.fold ff (λ a b, a || b.is_whitespace)

meta def json.of_string_list (xs : list string) : json :=
json.array (xs.map json.of_string)

meta inductive efmt
| compose (a b : efmt)
| of_string (s : string)
| nest (f : efmt)

namespace efmt

meta instance : has_append efmt := ⟨compose⟩
meta instance : has_coe string efmt := ⟨of_string⟩
meta instance coe_format : has_coe format efmt := ⟨of_string ∘ format.to_string⟩

meta def to_json : efmt → json
| (compose a b) := json.array ["c", a.to_json, b.to_json]
| (of_string f) := f
| (nest f) := json.array ["n", f.to_json]

meta def compose' : efmt → efmt → efmt
| (of_string a) (of_string b) := of_string (a ++ b)
| (of_string a) (compose (of_string b) c) := of_string (a ++ b) ++ c
| (compose a (of_string b)) (of_string c) := a ++ of_string (b ++ c)
| a b := compose a b

meta def of_eformat : eformat → efmt
| (tagged_format.group g) := of_eformat g
| (tagged_format.nest i g) := of_eformat g
| (tagged_format.tag _ g) := nest (of_eformat g)
| (tagged_format.highlight _ g) := of_eformat g
| (tagged_format.compose a b) := compose (of_eformat a) (of_eformat b)
| (tagged_format.of_format f) := of_string f.to_string

meta def sink_lparens_core : list string → efmt → efmt
| ps (of_string a) := of_string $ string.join (a :: ps : list string).reverse
| ps (compose (compose a b) c) :=
  sink_lparens_core ps (compose a (compose b c))
| ps (compose (of_string "") a) :=
  sink_lparens_core ps a
| ps (compose (of_string a) b) :=
  if a = "[" ∨ a = "(" ∨ a = "{" then
    sink_lparens_core (a :: ps) b
  else
    compose (sink_lparens_core ps (of_string a)) (sink_lparens_core [] b)
| ps (compose a b) := compose (sink_lparens_core ps a) (sink_lparens_core [] b)
| ps (nest a) := nest $ sink_lparens_core ps a

meta def sink_rparens_core : efmt → list string → efmt
| (of_string a) ps := of_string $ ps.foldl (++) a
| (compose a (compose b c)) ps :=
  sink_rparens_core (compose (compose a b) c) ps
| (compose a (of_string "")) ps :=
  sink_rparens_core a ps
| (compose a (of_string b)) ps :=
  if b = "]" ∨ b = ")" ∨ b = "}" then
    sink_rparens_core a (b :: ps)
  else
    compose (sink_rparens_core a []) (sink_rparens_core (of_string b) ps)
| (compose a b) ps := compose (sink_rparens_core a []) (sink_rparens_core b ps)
| (nest a) ps := nest $ sink_rparens_core a ps

meta def sink_parens (e : efmt) : efmt :=
sink_lparens_core [] $ sink_rparens_core e []

meta def simplify : efmt → efmt
| (compose a b) := compose' (simplify a) (simplify b)
| (nest (nest a)) := simplify $ nest a
| (nest a) :=
  match simplify a with
  | of_string a := if a.has_whitespace then nest (of_string a) else of_string a
  | a := nest a
  end
| (of_string a) := of_string a

meta def pp (e : expr) : tactic efmt :=
(simplify ∘ sink_parens ∘ of_eformat) <$> pp_tagged e

end efmt

/-- The information collected from each declaration -/
meta structure decl_info :=
(name : name)
(is_meta : bool)
(args : list (bool × efmt)) -- tt means implicit
(type : efmt)
(doc_string : option string)
(filename : string)
(line : ℕ)
(attributes : list string) -- not all attributes, we have a hardcoded list to check
(equations : list efmt)
(kind : string) -- def, thm, cnst, ax
(structure_fields : list (string × efmt)) -- name and type of fields of a constructor
(constructors : list (string × efmt)) -- name and type of constructors of an inductive type

structure module_doc_info :=
(filename : string)
(line : ℕ)
(content : string)

section
set_option old_structure_cmd true

structure ext_tactic_doc_entry extends tactic_doc_entry :=
(imported : string)

meta def ext_tactic_doc_entry.to_json : ext_tactic_doc_entry → json
| ⟨name, category, decl_names, tags, description, _, imported⟩ :=
json.object [
  ("name", name),
  ("category", category.to_string),
  ("decl_names", json.of_string_list (decl_names.map to_string)),
  ("tags", json.of_string_list tags),
  ("description", description),
  ("import", imported)]
end

meta def decl_info.to_json : decl_info → json
| ⟨name, is_meta, args, type, doc_string, filename, line, attributes, equations, kind, structure_fields, constructors⟩ :=
json.object [
  ("name", to_string name),
  ("is_meta", is_meta),
  ("args", json.array $ args.map $ λ ⟨b, s⟩, json.object [("arg", s.to_json), ("implicit", b)]),
  ("type", type.to_json),
  ("doc_string", doc_string.get_or_else ""),
  ("filename", filename),
  ("line", line),
  ("attributes", json.of_string_list attributes),
  ("equations", equations.map efmt.to_json),
  ("kind", kind),
  ("structure_fields", json.array $
    structure_fields.map (λ ⟨n, t⟩, json.array [to_string n, t.to_json])),
  ("constructors", json.array $
    constructors.map (λ ⟨n, t⟩, json.array [to_string n, t.to_json]))]

section

open tactic.interactive

-- tt means implicit
meta def format_binders (ns : list name) (bi : binder_info) (t : expr) : tactic (bool × efmt) := do
t' ← efmt.pp t,
let use_instance_style : bool := ns.length = 1
  ∧ "_".is_prefix_of ns.head.to_string
  ∧ bi = binder_info.inst_implicit,
let t' := if use_instance_style then t' else format_names ns ++ " : " ++ t',
let brackets : string × string := match bi with
  | binder_info.default := ("(", ")")
  | binder_info.implicit := ("{", "}")
  | binder_info.strict_implicit := ("⦃", "⦄")
  | binder_info.inst_implicit := ("[", "]")
  | binder_info.aux_decl := ("(", ")") -- TODO: is this correct?
  end,
pure $ prod.mk (bi ≠ binder_info.default : bool) $ (brackets.1 : efmt) ++ t' ++ brackets.2

meta def binder_info.is_inst_implicit : binder_info → bool
| binder_info.inst_implicit := tt
| _ := ff

-- Determines how many pis should be shown as named arguments.
meta def count_named_intros : expr → ℕ
| e@(expr.pi n bi d b) :=
  if e.is_arrow ∧ n = `ᾰ then
    0
  else
    count_named_intros (b.instantiate_var `(Prop)) + 1
| _ := 0

-- tt means implicit
meta def get_args_and_type (e : expr) : tactic (list (bool × efmt) × efmt) :=
prod.fst <$> solve_aux e (
do intron $ count_named_intros e,
   cxt ← local_context >>= tactic.interactive.compact_decl,
   cxt' ← cxt.mmap (λ t, do ft ← format_binders t.1 t.2.1 t.2.2, return (ft.1, ft.2)),
   tgt ← target >>= efmt.pp,
   return (cxt', tgt))

end

/-- The attributes we check for -/
meta def attribute_list := [`simp, `squash_cast, `move_cast, `elim_cast, `nolint, `ext, `instance, `class]

meta def attributes_of (n : name) : tactic (list string) :=
list.map to_string <$> attribute_list.mfilter (λ attr, succeeds $ has_attribute attr n)

meta def declaration.kind : declaration → string
| (declaration.defn a a_1 a_2 a_3 a_4 a_5) := "def"
| (declaration.thm a a_1 a_2 a_3) := "thm"
| (declaration.cnst a a_1 a_2 a_3) := "cnst"
| (declaration.ax a a_1 a_2) := "ax"

-- does this not exist already? I'm confused.
meta def expr.instantiate_pis : list expr → expr → expr
| (e'::es) (expr.pi n bi t e) := expr.instantiate_pis es (e.instantiate_var e')
| _        e              := e

meta def enable_links : tactic unit :=
do o ← get_options, set_options $ o.set_bool `pp.links tt

-- assumes proj_name exists
meta def get_proj_type (struct_name proj_name : name) : tactic efmt :=
do (locs, _) ← mk_const struct_name >>= infer_type >>= mk_local_pis,
   proj_tp ← mk_const proj_name >>= infer_type,
   (_, t) ← open_n_pis (proj_tp.instantiate_pis locs) 1,
   efmt.pp t

meta def mk_structure_fields (decl : name) (e : environment) : tactic (list (string × efmt)) :=
match e.is_structure decl, e.structure_fields_full decl with
| tt, some proj_names := proj_names.mmap $
    λ n, do tp ← get_proj_type decl n, return (to_string n, tp)
| _, _ := return []
end

-- this is used as a hack in get_constructor_type to avoid printing `Type ?`.
meta def mk_const_with_params (d : declaration) : expr :=
let lvls := d.univ_params.map level.param in
expr.const d.to_name lvls

meta def get_constructor_type (type_name constructor_name : name) : tactic efmt :=
do d ← get_decl type_name,
   (locs, _) ← infer_type (mk_const_with_params d) >>= mk_local_pis,
   env ← get_env,
   let locs := locs.take (env.inductive_num_params type_name),
   proj_tp ← mk_const constructor_name >>= infer_type,
   do t ← pis locs (proj_tp.instantiate_pis locs), --.abstract_locals (locs.map expr.local_uniq_name),
   efmt.pp t

meta def mk_constructors (decl : name) (e : environment): tactic (list (string × efmt)) :=
if (¬ e.is_inductive decl) ∨ (e.is_structure decl) then return [] else
do d ← get_decl decl, ns ← get_constructors_for (mk_const_with_params d),
   ns.mmap $ λ n, do tp ← get_constructor_type decl n, return (to_string n, tp)

meta def get_equations (decl : name) : tactic (list efmt) := do
decl_is_proof ← mk_const decl >>= is_proof,
if decl_is_proof then return []
else do
  ns ← get_eqn_lemmas_for tt decl,
  ns.mmap $ λ n, do
  d ← get_decl n,
  (_, ty) ← mk_local_pis d.type,
  efmt.pp ty

/-- extracts `decl_info` from `d`. Should return `none` instead of failing. -/
meta def process_decl (d : declaration) : tactic (option decl_info) :=
do ff ← d.in_current_file | return none,
   e ← get_env,
   let decl_name := d.to_name,
   if decl_name.is_internal ∨ d.is_auto_generated e then return none else do
   some filename ← return (e.decl_olean decl_name) | return none,
   some ⟨line, _⟩ ← return (e.decl_pos decl_name) | return none,
   doc_string ← (some <$> doc_string decl_name) <|> return none,
   (args, type) ← get_args_and_type d.type,
   attributes ← attributes_of decl_name,
   equations ← get_equations decl_name,
   structure_fields ← mk_structure_fields decl_name e,
   constructors ← mk_constructors decl_name e,
   return $ some ⟨decl_name, !d.is_trusted, args, type, doc_string, filename, line, attributes, equations, d.kind, structure_fields, constructors⟩

meta def write_module_doc_pair : pos × string → json
| (⟨line, _⟩, doc) := json.object [("line", line), ("doc", doc)]

meta def write_olean_docs : tactic (list (string × json)) :=
do docs ← olean_doc_strings,
   return (docs.foldl (λ rest p, match p with
   | (none, _) := rest
   | (some filename, l) :=
     (filename, json.array $ l.map write_module_doc_pair) :: rest
   end) [])

meta def get_instances : tactic (rb_lmap string string) :=
attribute.get_instances `instance >>= list.mfoldl
  (λ map inst_nm,
   do ty ← mk_const inst_nm >>= infer_type,
      (_, e) ← open_pis_whnf ty transparency.reducible,
      e ← whnf e transparency.reducible,
      expr.const class_nm _ ← pure e.get_app_fn |
        fail ("not a constant: " ++ to_string e),
      return $ map.insert class_nm.to_string inst_nm.to_string)
  mk_rb_map

meta def format_instance_list : tactic json :=
do map ← get_instances,
   pure $ json.object $ map.to_list.map (λ ⟨n, l⟩, (n, json.of_string_list l))

meta def format_notes : tactic json :=
do l ← get_library_notes,
   pure $ json.array $ l.map $ λ ⟨l, r⟩, json.array [l, r]

meta def name.imported_by_tactic_basic (decl_name : name) : bool :=
let env := environment.from_imported_module_name `tactic.basic in
env.contains decl_name

meta def name.imported_by_tactic_default (decl_name : name) : bool :=
let env := environment.from_imported_module_name `tactic.default in
env.contains decl_name

meta def name.imported_always (decl_name : name) : bool :=
let env := environment.from_imported_module_name `system.random in
env.contains decl_name

meta def tactic_doc_entry.add_import : tactic_doc_entry → ext_tactic_doc_entry
| ⟨name, category, [], tags, description, idf⟩ := ⟨name, category, [], tags, description, idf, ""⟩
| ⟨name, category, rel_decls@(decl_name::_), tags, description, idf⟩ :=
  let imported := if decl_name.imported_always then "always imported"
                  else if decl_name.imported_by_tactic_basic then "tactic.basic"
                  else if decl_name.imported_by_tactic_default then "tactic"
                  else "" in
  ⟨name, category, rel_decls, tags, description, idf, imported⟩

meta def format_tactic_docs : tactic json :=
do l ← list.map tactic_doc_entry.add_import <$> get_tactic_doc_entries,
   return $ l.map ext_tactic_doc_entry.to_json

meta def mk_export_json : tactic json := do
e ← get_env,
s ← read,
let decls := list.reduce_option $ e.get_decls.map_async_chunked $ λ decl,
match (enable_links *> process_decl decl) s with
| result.success (some di) _ := some di.to_json
| _:= none
end,
mod_docs ← write_olean_docs,
notes ← format_notes,
tactic_docs ← format_tactic_docs,
instl ← format_instance_list,
pure $ json.object [
  ("decls", decls),
  ("mod_docs", json.object mod_docs),
  ("notes", notes),
  ("tactic_docs", tactic_docs),
  ("instances", instl)
]

open lean.parser
@[user_command]
meta def open_all_locales (_ : interactive.parse (tk "open_all_locales")): lean.parser unit :=
do m ← of_tactic localized_attr.get_cache,
   cmds ← of_tactic $ get_localized m.keys,
   cmds.mmap' $ λ m,
    when (¬ ∃ tok ∈ m.split_on '`', by exact
        (tok.length = 1 ∧ tok.front.is_alphanum) ∨ tok ∈ ["ε", "φ", "ψ", "W_", "σ", "ζ"]) $
    lean.parser.emit_code_here m <|> skip

meta def main : io unit := do
json ← run_tactic (trace_error "export_json failed:" mk_export_json),
put_str json.unparse

-- HACK: print gadgets with less fluff
notation x ` := `:10 y := opt_param x y
-- HACKIER: print last component of name as string (because we can't do any better...)
notation x ` . `:10 y := auto_param x (name.mk_string y _)
