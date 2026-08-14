"use strict";

var assert = require("node:assert/strict");
var test = require("node:test");
var commentPrResults = require("./comment_pr_results.js");

var ENV = {
    RUNNER_TEMP: "/runner/temp",
    TEST_RESULT: "success",
    COMPLEXITY_RESULT: "success",
    BUILD_RESULT: "success",
    SYNTAX_RESULT: "success",
    STAMP_RESULT: "success",
    LINT_THIN_RESULT: "success",
    LINT_BUNDLED_RESULT: "failure",
};

function fileSystem(files) {
    return {
        existsSync: function (filePath) {
            return Object.hasOwn(files, filePath);
        },
        readFileSync: function (filePath) {
            return files[filePath];
        },
    };
}

function githubClient(comments) {
    var calls = { created: [], updated: [] };
    return {
        calls: calls,
        rest: {
            issues: {
                listComments: async function () {
                    return { data: comments };
                },
                updateComment: async function (request) {
                    calls.updated.push(request);
                },
                createComment: async function (request) {
                    calls.created.push(request);
                },
            },
        },
    };
}

test("buildComment includes complexity details", function () {
    var files = {
        "/runner/temp/lua-complexity.json": JSON.stringify({
            summary: { changed_warning_functions: 2 },
        }),
        "/runner/temp/lua-complexity.md": "### Lua complexity details",
    };

    var body = commentPrResults.buildComment(ENV, fileSystem(files));

    assert.match(body, /\| Lua complexity \| ⚠️ 2 changed warnings \|/);
    assert.match(body, /\| Lint \(bundled\) \| ❌ failure \|/);
    assert.match(body, /### Lua complexity details/);
});

test("commentPrResults updates the existing CI comment", async function () {
    var github = githubClient([
        { id: 41, user: { type: "User" }, body: "## CI Results" },
        { id: 42, user: { type: "Bot" }, body: "## CI Results\nold" },
    ]);

    await commentPrResults({
        github: github,
        context: { repo: { owner: "owner", repo: "repo" }, issue: { number: 7 } },
        env: ENV,
        fileSystem: fileSystem({}),
    });

    assert.equal(github.calls.created.length, 0);
    assert.equal(github.calls.updated.length, 1);
    assert.equal(github.calls.updated[0].comment_id, 42);
    assert.match(github.calls.updated[0].body, /^## CI Results/);
});

test("commentPrResults creates a CI comment when none exists", async function () {
    var github = githubClient([]);

    await commentPrResults({
        github: github,
        context: { repo: { owner: "owner", repo: "repo" }, issue: { number: 7 } },
        env: ENV,
        fileSystem: fileSystem({}),
    });

    assert.equal(github.calls.updated.length, 0);
    assert.equal(github.calls.created.length, 1);
    assert.equal(github.calls.created[0].issue_number, 7);
    assert.match(github.calls.created[0].body, /^## CI Results/);
});
