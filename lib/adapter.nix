{ lib }:
let
  engineConcern = import ./engine { inherit lib; };

  engines = {
    # Each engine carries its lib AND evalModules so the host tier (runHost) can thread the
    # engine's possibly-extended lib into eval-config.
    vanilla = {
      lib = lib;
      evalModules = lib.evalModules;
    };
    # identity: lib.extend passthrough — byte-identical output, routes through the SAME override
    # seam the engine arm will later replace (submodule extendModules bypass, §4 HC5).
    identity =
      let
        elib = lib.extend (
          final: prev: {
            modules = prev.modules // {
              evalModules = a: prev.modules.evalModules a;
            };
          }
        );
      in
      {
        lib = elib;
        evalModules = elib.evalModules;
      };
    # engine: the vendored-body seam — mkEngine overrides `final.modules` ALONE (lib/engine), so
    # the whole module surface (evalModules/mkIf/…) routes through the owned copy via the fixpoint.
    engine = engineConcern.engine;
  };

  # value / synthetic / landmine tier:
  run =
    engine: fx:
    engine.evalModules (
      {
        inherit (fx) modules;
        specialArgs = fx.specialArgs or { };
      }
      // (if (fx.class or null) == null then { } else { inherit (fx) class; })
    );

  # host tier (gate="drvPath"): dual-run through eval-config, threading the engine's lib so the
  # override reaches the host evaluator (eval-config builds its evaluator from its `lib` arg).
  runHost =
    engine: fx:
    import fx.evalConfig {
      inherit (engine) lib;
      system = "x86_64-linux";
      modules = fx.modules;
    };

  # Den-template tier (gate="drvPath"): invoke the template's RAW outputs with inputs.nixpkgs.lib
  # doctored to the engine's lib (full-surface), return the host NixOS eval result.
  runDenTemplate =
    engine: fx:
    let
      t = fx.denTemplate;
      raw = import (t.den.outPath + "/templates/${t.template}/flake.nix");
      out = raw.outputs {
        nixpkgs = t.nixpkgsFlake // {
          lib = engine.lib;
        };
        import-tree = t.importTree;
        den = t.den;
      };
    in
    t.hostOf out;

  # Build the engine lib from an ARBITRARY base lib (the host's channel lib), so the vendored body
  # rides the SAME nixpkgs the host really uses. `import ./engine { lib = baseLib; }` re-instantiates
  # the engine module against baseLib (no engine change — the module is `{ lib }:`-shaped).
  fleetEngineLib = baseLib: (import ./engine { lib = baseLib; }).engine.lib;

  # baseline-composition witness (A1 — MEASUREMENT.md §baseline-composition): a DERIVATION-FREE
  # structure walk of a fleet cfg's merged option tree. Forcing it runs den's aspect resolution + the
  # full module-system declaration merge (which modules apply, their option surface) but stops before
  # value realization: it prunes option/type nodes (`_type`) and derivations (`type == "derivation"`)
  # at WHNF, so no leaf value and no drvPath is ever forced. It therefore completes deterministically,
  # unlike a `cfg.config` walk (agenix-rekey secrets + structured systemd/quirk accessors throw on
  # coercion, so a config deepSeq measures only "work up to the first throw"). Spec expression is
  # verbatim from MEASUREMENT.md.
  compositionWalk =
    x:
    if !(builtins.isAttrs x) then
      null
    else if (x._type or null) != null then
      null # stop AT each option node
    else if (x.type or null) == "derivation" then
      null # never force a drvPath
    else
      builtins.deepSeq (builtins.map compositionWalk (builtins.attrValues x)) (builtins.attrNames x);

  # The walk's OUTPUT: the merged option tree's top-level attr-name list, returned only after the full
  # recursive walk has been deep-forced. A per-host structural fingerprint — hash this for the
  # composition arm's parity digest (it changes iff the declared top-level option set changes, so a
  # resolution-only optimization like the class-share arm must leave it byte-identical).
  compositionNames = cfg: compositionWalk cfg.options;

  # Spec-exact witness: force the whole walk, yield `true` (MEASUREMENT.md's standalone recipe
  # references it). The stat driver's composition arm does NOT force this expression — it forces
  # `hashString (toJSON (compositionNames cfg))`, i.e. the SAME walk plus a toJSON+hash of the small
  # top-level name list for the digest column. Not the identical expression, but the added toJSON/hash
  # is negligible: measured at fleet scale the arm's nrFunctionCalls / nrPrimOpCalls match this
  # witness's 1-host anchor to the digit.
  compositionWitness = cfg: builtins.deepSeq (compositionNames cfg) true;

  # Arm R (rebuild-dedup — MEASUREMENT.md §rebuild-dedup): model the fleet as a gen-rebuild graph and
  # re-assert gen-rebuild's soundness oracle on the REAL corpus. Nodes = a shared class-composition
  # producer + the fleet hosts; edge host→shared (each host depends on the shared composition, gen-graph
  # convention `edges id = deps of id`). `recompute host` forces the host's REAL compositionNames (the
  # expensive per-host work) folded with the node's data + the shared value, so a localized single-host
  # DATA edit moves only that host's hash (cone = {host}) while a shared-node edit moves all (pessimal).
  #
  # `genRebuild` is INJECTED (the demo's `{ genRebuild }` pattern) — hola's lib stays gen-rebuild-free
  # (no import), so this adds no dependency; the caller getFlakes the pinned gen-rebuild and passes .lib.
  # `compFor host` is the caller-supplied composition witness (`compositionNames (runDenFleet … host)`),
  # kept a param so this helper never reaches into the corpus module.
  #
  # Returns the demo's soundness record on the real graph: `resultEqualsFullRebuild` (THE byte gate —
  # propagateEager's store == a from-scratch build with the same edit) + `coneOnlyRecompute` (a POISONED
  # recompute that throws on the untouched hosts proves they are never re-evaluated) + the cone/untouched
  # partition. The dedup WIN is reuse-ACROSS-CHANGE: a single-host edit skips the untouched hosts' evals;
  # its counter value = Σ of the skipped hosts' baseline-composition counters (arithmetic on the Task-6
  # baseline, NOT a single-eval speedup — gen-rebuild does not beat O(|cone|) in one pure eval).
  fleetRebuildSoundness =
    {
      genRebuild,
      compFor,
      hosts,
      editHost,
    }:
    let
      inherit (genRebuild) build propagateEager dirtySet;
      hashOf = v: builtins.hashString "sha256" (builtins.toJSON v);
      nodeIds = [ "shared" ] ++ hosts;
      mkAcc = nodeDataMap: edgesMap: {
        nodes = nodeIds;
        edges = id: edgesMap.${id} or [ ];
        nodeData = id: nodeDataMap.${id} or { };
        parent = _id: null;
      };
      baseData = builtins.listToAttrs (
        map (id: {
          name = id;
          value = {
            rev = "base";
          };
        }) nodeIds
      );
      fleetEdges = {
        shared = [ ];
      }
      // builtins.listToAttrs (
        map (h: {
          name = h;
          value = [ "shared" ];
        }) hosts
      );
      fleet = mkAcc baseData fleetEdges;
      # recompute: the shared node hashes only its data; a host folds its REAL composition with its data
      # and the shared value (so the shared node is a genuine dependency for the pessimal case).
      recompute =
        acc: s: id:
        if id == "shared" then
          hashOf (acc.nodeData id)
        else
          hashOf {
            host = id;
            comp = compFor id;
            data = acc.nodeData id;
            shared = s.shared;
          };

      ctx = build {
        accessor = fleet;
        inherit recompute hashOf;
      };
      newDecls = {
        rev = "edited";
      };
      overridden = propagateEager ctx { ${editHost} = newDecls; };

      # Ground truth: a full from-scratch build with editHost's data replaced.
      fleet' = fleet // {
        nodeData = id: if id == editHost then newDecls else fleet.nodeData id;
      };
      fullRebuild = build {
        accessor = fleet';
        inherit recompute hashOf;
      };

      cone = dirtySet ctx [ editHost ];
      untouched = builtins.filter (id: !(builtins.elem id cone)) fleet.nodes;
      # Poisoned recompute: throws on the untouched hosts. propagateEager splices their prior values and
      # must never call recompute on them, so it succeeds; the asymmetry proves cone-only recompute
      # WITHOUT forcing the untouched compositions.
      poison =
        acc: s: id:
        if builtins.elem id untouched then throw "POISON: ${id} recomputed" else recompute acc s id;
      overrideWithPoison = propagateEager (ctx // { recompute = poison; }) { ${editHost} = newDecls; };
    in
    {
      editHost = editHost;
      recomputedCone = builtins.sort builtins.lessThan cone;
      untouchedNodes = builtins.sort builtins.lessThan untouched;
      # THE byte gate: incremental store == from-scratch build with the edit applied.
      resultEqualsFullRebuild = overridden.store == fullRebuild.store;
      untouchedReused = builtins.all (id: overridden.store.${id} == ctx.store.${id}) untouched;
      coneOnlyRecompute = (builtins.tryEval (builtins.deepSeq overrideWithPoison.store true)).success;
    };

  # Fleet tier (gate="drvPath"): re-invoke nix-config's RAW outputs with the host's channel input's
  # .lib replaced by `doctor channelLib`, + the lazy outPath-carrying self-knot. Pure: a declared
  # flake input exposes .inputs/.outPath. `self` is the ONE input getFlake omits and the toplevel both
  # string-coerces it (host.nix:391) AND forces self.overlays.default (nixpkgs.nix:16) — the lazy
  # `out` fixpoint carrying outPath/sourceInfo supplies both. `doctor = id` ⇒ host's REAL build;
  # `doctor = fleetEngineLib` ⇒ host's build with the engine. Identical iff vendored ≡ channel modules.nix.
  runDenFleet =
    doctor: fx:
    let
      f = fx.denFleet;
      nc = f.nixConfig;
      chan = nc.inputs.${f.channelInput};
      raw = import (nc.outPath + "/flake.nix");
      out = raw.outputs (
        nc.inputs
        // {
          self = out // {
            outPath = nc.outPath;
            inherit (nc) sourceInfo;
          };
          ${f.channelInput} = chan // {
            lib = doctor chan.lib;
          };
        }
      );
    in
    out.nixosConfigurations.${f.host};
in
{
  inherit
    engines
    run
    runHost
    runDenTemplate
    fleetEngineLib
    runDenFleet
    compositionWalk
    compositionNames
    compositionWitness
    fleetRebuildSoundness
    ;
}
