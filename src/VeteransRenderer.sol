// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title VETERANS on-chain renderer — Pepe miner pixel art derived from the winning PoW hash.
/// @notice Fully on-chain, stateless. `tokenURI` returns a base64 data URI with OpenSea-compatible JSON
///         (name, description, image as inline SVG, attributes incl. a numeric rarity score).
/// @dev    Every trait roll reads one byte of the seed, so the hash controls visuals only.
///         Trait odds (per 100): see the `_pick` tables. "Overclocked" tier hits when seed byte 7 % 24 == 0.
contract VeteransRenderer {
    using Strings for uint256;

    uint256 public constant EPOCH_SIZE = 333;
    uint256 public constant OVERCLOCK_ODDS = 24; // ~1 in 24

    struct Traits {
        uint8 background;
        uint8 helmet;
        uint8 headlamp;
        uint8 eyes;
        uint8 tool;
        bool overclocked;
    }

    // ──────────────────────────────────────── Traits ────────────────────────────────────────

    /// @notice Decodes the visual traits from a seed.
    function traitsOf(bytes32 seed) public pure returns (Traits memory t) {
        t.background = _pick(uint8(seed[0]), _bgOdds());
        t.helmet = _pick(uint8(seed[1]), _helmetOdds());
        t.headlamp = _pick(uint8(seed[2]), _lampOdds());
        t.eyes = _pick(uint8(seed[3]), _eyesOdds());
        t.tool = _pick(uint8(seed[4]), _toolOdds());
        t.overclocked = uint8(seed[7]) % OVERCLOCK_ODDS == 0;
    }

    /// @notice Rarity score: sum of 10000 / odds(%) over the rolled traits, plus the tier bonus.
    function rarityScore(bytes32 seed) public pure returns (uint256 score) {
        Traits memory t = traitsOf(seed);
        score = 10_000 / _bgOdds()[t.background] + 10_000 / _helmetOdds()[t.helmet] + 10_000 / _lampOdds()[t.headlamp]
            + 10_000 / _eyesOdds()[t.eyes] + 10_000 / _toolOdds()[t.tool];
        score += t.overclocked ? 10_000 * OVERCLOCK_ODDS / 10 : 10_000 * OVERCLOCK_ODDS / (10 * (OVERCLOCK_ODDS - 1));
    }

    function _pick(uint8 roll, uint8[5] memory odds) private pure returns (uint8) {
        uint256 r = roll % 100;
        uint256 acc;
        for (uint8 i; i < 5; ++i) {
            acc += odds[i];
            if (r < acc) return i;
        }
        return 4;
    }

    function _bgOdds() private pure returns (uint8[5] memory) {
        return [40, 25, 18, 12, 5];
    }

    function _helmetOdds() private pure returns (uint8[5] memory) {
        return [35, 25, 20, 12, 8];
    }

    function _lampOdds() private pure returns (uint8[5] memory) {
        return [40, 30, 15, 10, 5];
    }

    function _eyesOdds() private pure returns (uint8[5] memory) {
        return [45, 25, 15, 10, 5];
    }

    function _toolOdds() private pure returns (uint8[5] memory) {
        return [35, 25, 20, 14, 6];
    }

    function backgroundName(uint8 i) public pure returns (string memory) {
        return ["Terminal Black", "Deep Shaft", "Matrix Rain", "Blue Shift", "Crimson Core"][i];
    }

    function helmetName(uint8 i) public pure returns (string memory) {
        return ["Yellow Hardhat", "Green Hardhat", "Red Hardhat", "Chrome Dome", "Bare Head"][i];
    }

    function headlampName(uint8 i) public pure returns (string memory) {
        return ["Off", "On", "Wide Beam", "Laser", "Strobe"][i];
    }

    function eyesName(uint8 i) public pure returns (string memory) {
        return ["Focused", "Tired", "Shades", "Laser Eyes", "Terminal Glow"][i];
    }

    function toolName(uint8 i) public pure returns (string memory) {
        return ["Pickaxe", "Shovel", "Keyboard", "Drill", "Diamond Pick"][i];
    }

    // ─────────────────────────────────────── tokenURI ───────────────────────────────────────

    function tokenURI(uint256 tokenId, bytes32 seed) external pure returns (string memory) {
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(tokenJSON(tokenId, seed))));
    }

    /// @notice Raw metadata JSON (what `tokenURI` base64-encodes); handy for indexers and the frontend.
    function tokenJSON(uint256 tokenId, bytes32 seed) public pure returns (bytes memory) {
        Traits memory t = traitsOf(seed);
        string memory image = Base64.encode(bytes(svg(t)));
        return abi.encodePacked(
            '{"name":"VETERAN #',
            tokenId.toString(),
            '","description":"VETERANS: proof-of-work mined Pepe miners on Robinhood Chain. 3,333 miners, 10 epochs, wallet-age staking multipliers. Traits are derived from the winning PoW hash.",',
            '"image":"data:image/svg+xml;base64,',
            image,
            '","attributes":',
            _attributes(tokenId, seed, t),
            "}"
        );
    }

    function _attributes(uint256 tokenId, bytes32 seed, Traits memory t) private pure returns (bytes memory) {
        return abi.encodePacked(
            "[",
            _attr("Background", backgroundName(t.background)),
            ",",
            _attr("Helmet", helmetName(t.helmet)),
            ",",
            _attr("Headlamp", headlampName(t.headlamp)),
            ",",
            _attr("Eyes", eyesName(t.eyes)),
            ",",
            _attr("Tool", toolName(t.tool)),
            ",",
            _attr("Tier", t.overclocked ? "Overclocked" : "Veteran"),
            ',{"trait_type":"Epoch","display_type":"number","value":',
            ((tokenId - 1) / EPOCH_SIZE + 1).toString(),
            '},{"trait_type":"Rarity Score","display_type":"number","value":',
            rarityScore(seed).toString(),
            "}]"
        );
    }

    function _attr(string memory key, string memory value) private pure returns (bytes memory) {
        return abi.encodePacked('{"trait_type":"', key, '","value":"', value, '"}');
    }

    // ───────────────────────────────────────── SVG ─────────────────────────────────────────

    /// @notice 24×24 pixel-art SVG of the miner described by `t`.
    function svg(Traits memory t) public pure returns (string memory) {
        bytes memory lower = abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="480" height="480" shape-rendering="crispEdges">',
            _defs(t),
            _background(t),
            _body(t),
            _head(t)
        );
        bytes memory upper = abi.encodePacked(_eyes(t), _mouth(t), _helmet(t), _headlamp(t), _tool(t));
        return string(
            abi.encodePacked(
                lower,
                upper,
                t.overclocked
                    ? '<rect x="0.5" y="0.5" width="23" height="23" fill="none" stroke="#ffd166" stroke-width="1"/>'
                    : "",
                "</svg>"
            )
        );
    }

    function _defs(Traits memory t) private pure returns (string memory) {
        if (!t.overclocked) return "";
        return '<defs><filter id="g" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="0.8" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>';
    }

    function _background(Traits memory t) private pure returns (bytes memory out) {
        string[5] memory bg = ["#0b0f0c", "#111318", "#06140a", "#0a1020", "#1a0608"];
        out = abi.encodePacked(_rect(0, 0, 24, 24, bg[t.background]));
        if (t.background == 2) {
            // Matrix rain: falling green columns.
            out = abi.encodePacked(
                out,
                _rect(2, 0, 1, 7, "#1f7a2e"),
                _rect(21, 3, 1, 9, "#1f7a2e"),
                _rect(5, 12, 1, 12, "#17502a"),
                _rect(23, 0, 1, 5, "#34d058")
            );
        } else if (t.background == 0) {
            // Terminal: prompt bar.
            out = abi.encodePacked(out, _rect(1, 1, 1, 1, "#39ff14"), _rect(3, 1, 4, 1, "#1c3a22"));
        } else if (t.background == 3) {
            out = abi.encodePacked(out, _rect(0, 22, 24, 2, "#13204a"));
        } else if (t.background == 4) {
            out = abi.encodePacked(out, _rect(0, 21, 24, 3, "#4a0d12"), _rect(3, 20, 2, 1, "#ff3b3b"));
        }
    }

    function _body(Traits memory t) private pure returns (bytes memory) {
        string memory shirt = t.overclocked ? "#3a2f00" : "#2a2d33";
        string memory stripe = t.overclocked ? "#ffd166" : "#39ff14";
        return abi.encodePacked(
            _rect(5, 17, 14, 7, shirt),
            _rect(5, 20, 14, 1, stripe),
            _rect(10, 17, 4, 2, t.overclocked ? "#b8860b" : "#2f8f3a")
        );
    }

    function _head(Traits memory t) private pure returns (bytes memory) {
        string memory skin = t.overclocked ? "#e6b422" : "#3f9a41";
        string memory shade = t.overclocked ? "#b8860b" : "#2f7a32";
        bytes memory head = abi.encodePacked(
            _rect(6, 6, 12, 10, skin), _rect(7, 5, 10, 1, skin), _rect(7, 16, 10, 1, skin), _rect(6, 14, 12, 2, shade)
        );
        if (t.overclocked) {
            head = abi.encodePacked('<g filter="url(#g)">', head, "</g>");
        }
        return head;
    }

    function _eyes(Traits memory t) private pure returns (bytes memory) {
        if (t.eyes == 2) {
            // Shades.
            return
                abi.encodePacked(
                    _rect(7, 8, 10, 2, "#000"), _rect(8, 8, 1, 1, "#4b4b4b"), _rect(14, 8, 1, 1, "#4b4b4b")
                );
        }
        if (t.eyes == 3) {
            // Laser eyes: red beams to the right edge.
            return abi.encodePacked(
                _rect(8, 8, 3, 2, "#fff"),
                _rect(13, 8, 3, 2, "#fff"),
                _rect(10, 8, 1, 2, "#ff2d2d"),
                _rect(15, 8, 1, 2, "#ff2d2d"),
                _rect(11, 8, 13, 1, "#ff2d2d"),
                _rect(16, 9, 8, 1, "#ff6b6b")
            );
        }
        if (t.eyes == 4) {
            return abi.encodePacked(
                _rect(8, 8, 3, 2, "#39ff14"),
                _rect(13, 8, 3, 2, "#39ff14"),
                _rect(10, 8, 1, 2, "#0b0f0c"),
                _rect(15, 8, 1, 2, "#0b0f0c")
            );
        }
        bytes memory eyes = abi.encodePacked(
            _rect(8, 8, 3, 2, "#fff"),
            _rect(13, 8, 3, 2, "#fff"),
            _rect(10, 8, 1, 2, "#000"),
            _rect(15, 8, 1, 2, "#000")
        );
        if (t.eyes == 1) {
            // Tired: heavy lids.
            eyes = abi.encodePacked(eyes, _rect(8, 8, 3, 1, "#2f7a32"), _rect(13, 8, 3, 1, "#2f7a32"));
        }
        return eyes;
    }

    function _mouth(Traits memory t) private pure returns (bytes memory) {
        return
            abi.encodePacked(_rect(8, 12, 8, 1, t.overclocked ? "#5a4300" : "#1e4d21"), _rect(7, 11, 1, 1, "#1e4d21"));
    }

    function _helmet(Traits memory t) private pure returns (bytes memory) {
        if (t.helmet == 4) return "";
        string[4] memory colors = ["#f5c518", "#2fbf71", "#e63946", "#c0c6cc"];
        string memory c = colors[t.helmet];
        return abi.encodePacked(
            _rect(6, 2, 12, 3, c), _rect(7, 1, 10, 1, c), _rect(5, 5, 14, 1, c), _rect(9, 2, 2, 2, "#ffffff80")
        );
    }

    function _headlamp(Traits memory t) private pure returns (bytes memory) {
        if (t.headlamp == 0) return _rect(10, 3, 4, 1, "#555");
        if (t.headlamp == 3) {
            return abi.encodePacked(_rect(10, 3, 4, 1, "#ff2d2d"), _rect(14, 3, 10, 1, "#ff2d2d"));
        }
        if (t.headlamp == 4) {
            return abi.encodePacked(
                _rect(10, 3, 4, 1, "#fff"),
                _rect(14, 3, 2, 1, "#fff"),
                _rect(18, 3, 2, 1, "#fff"),
                _rect(22, 3, 2, 1, "#fff")
            );
        }
        bytes memory beam = _rect(14, 3, 10, 1, "#fff5b0");
        if (t.headlamp == 2) {
            beam = abi.encodePacked(beam, _rect(16, 2, 8, 1, "#fff5b060"), _rect(16, 4, 8, 1, "#fff5b060"));
        }
        return abi.encodePacked(_rect(10, 3, 4, 1, "#fff"), beam);
    }

    function _tool(Traits memory t) private pure returns (bytes memory) {
        if (t.tool == 0) {
            return abi.encodePacked(
                _rect(20, 10, 1, 12, "#8b5a2b"), _rect(17, 9, 7, 1, "#9aa0a6"), _rect(18, 8, 5, 1, "#9aa0a6")
            );
        }
        if (t.tool == 1) {
            return abi.encodePacked(_rect(20, 10, 1, 10, "#8b5a2b"), _rect(19, 20, 3, 3, "#9aa0a6"));
        }
        if (t.tool == 2) {
            return abi.encodePacked(
                _rect(0, 19, 7, 3, "#20242a"), _rect(1, 20, 5, 1, "#39ff14"), _rect(1, 21, 2, 1, "#39ff14")
            );
        }
        if (t.tool == 3) {
            return abi.encodePacked(
                _rect(19, 12, 3, 3, "#f5c518"), _rect(22, 13, 2, 1, "#9aa0a6"), _rect(19, 15, 1, 5, "#f5c518")
            );
        }
        return abi.encodePacked(
            _rect(20, 10, 1, 12, "#8b5a2b"),
            _rect(17, 9, 7, 1, "#7df9ff"),
            _rect(18, 8, 5, 1, "#7df9ff"),
            _rect(19, 7, 3, 1, "#e0ffff")
        );
    }

    function _rect(uint256 x, uint256 y, uint256 w, uint256 h, string memory fill) private pure returns (bytes memory) {
        return abi.encodePacked(
            '<rect x="',
            x.toString(),
            '" y="',
            y.toString(),
            '" width="',
            w.toString(),
            '" height="',
            h.toString(),
            '" fill="',
            fill,
            '"/>'
        );
    }
}
