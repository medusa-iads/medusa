"use strict";

var fs = require("node:fs");
var path = require("node:path");

var COMMENT_HEADING = "## CI Results";

function icon(result) {
    return result === "success" ? "✅" : "❌";
}

function complexityStatus(env, fileSystem) {
    var result = env.COMPLEXITY_RESULT;
    var reportPath = path.join(env.RUNNER_TEMP, "lua-complexity.json");
    if (result !== "success" || !fileSystem.existsSync(reportPath)) {
        return icon(result) + " " + result;
    }

    var report = JSON.parse(fileSystem.readFileSync(reportPath, "utf8"));
    var warningCount = report.summary.changed_warning_functions;
    if (warningCount === 0) {
        return "✅ no changed warnings";
    }
    return "⚠️ " + warningCount + " changed warning" + (warningCount === 1 ? "" : "s");
}

function buildComment(env, fileSystem) {
    var lines = [
        COMMENT_HEADING,
        "",
        "| Check | Result |",
        "|-------|--------|",
        "| Tests | " + icon(env.TEST_RESULT) + " " + env.TEST_RESULT + " |",
        "| Lua complexity | " + complexityStatus(env, fileSystem) + " |",
        "| Build | " + icon(env.BUILD_RESULT) + " " + env.BUILD_RESULT + " |",
        "| Syntax | " + icon(env.SYNTAX_RESULT) + " " + env.SYNTAX_RESULT + " |",
        "| Version stamp | " + icon(env.STAMP_RESULT) + " " + env.STAMP_RESULT + " |",
        "| Lint (thin) | " + icon(env.LINT_THIN_RESULT) + " " + env.LINT_THIN_RESULT + " |",
        "| Lint (bundled) | " + icon(env.LINT_BUNDLED_RESULT) + " " + env.LINT_BUNDLED_RESULT + " |",
    ];

    var reportPath = path.join(env.RUNNER_TEMP, "lua-complexity.md");
    if (fileSystem.existsSync(reportPath)) {
        lines.push("", fileSystem.readFileSync(reportPath, "utf8"));
    }
    return lines.join("\n");
}

async function commentPrResults(options) {
    var github = options.github;
    var context = options.context;
    var env = options.env || process.env;
    var fileSystem = options.fileSystem || fs;
    var body = buildComment(env, fileSystem);
    var issue = {
        owner: context.repo.owner,
        repo: context.repo.repo,
        issue_number: context.issue.number,
    };
    var response = await github.rest.issues.listComments(issue);
    var botComment = response.data.find(function (comment) {
        return comment.user.type === "Bot" && comment.body.includes(COMMENT_HEADING);
    });

    if (botComment) {
        return github.rest.issues.updateComment({
            owner: issue.owner,
            repo: issue.repo,
            comment_id: botComment.id,
            body: body,
        });
    }
    return github.rest.issues.createComment({
        owner: issue.owner,
        repo: issue.repo,
        issue_number: issue.issue_number,
        body: body,
    });
}

module.exports = commentPrResults;
module.exports.buildComment = buildComment;
