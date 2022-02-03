package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"

	"github.com/andygrunwald/go-jira"
	"github.com/google/go-github/v37/github"
	"golang.org/x/oauth2"
)

var addToCurrentSprintFlag = flag.Bool("addToCurrentSprint", false, "add the ticket to the current sprint")

// secrets!
var githubToken = os.Getenv("GITHUB_TOKEN")
var jiraToken = os.Getenv("JIRA_TOKEN")

// not really secrets but stuff where you're likely to differ from me!
var targetGithubOrg = os.Getenv("TARGET_GITHUB_ORG")
var sourceGithubOrg = os.Getenv("SOURCE_GITHUB_ORG")
var targetGithubRepo = os.Getenv("TARGET_GITHUB_REPO")
var jiraAccountId = os.Getenv("JIRA_ACCOUNT_ID")
var jiraUsername = os.Getenv("JIRA_USER_NAME")
var jiraUrl = os.Getenv("JIRA_URL")
var jiraProjectName = os.Getenv("JIRA_PROJECT_NAME")
var jiraBoardID = os.Getenv("JIRA_BOARD_ID")
var jiraSprintFieldName = os.Getenv("JIRA_SPRINT_FIELD_NAME")

const jiraIssueType = "Chore"
const targetGithubBranch = "main"

func main() {
	if githubToken == "" {
		fmt.Println("GITHUB_TOKEN env var must be set")
		os.Exit(1)
	}
	if jiraToken == "" {
		fmt.Println("JIRA_TOKEN env var must be set")
		os.Exit(1)
	}
	ctx := context.Background()
	ts := oauth2.StaticTokenSource(
		&oauth2.Token{AccessToken: githubToken},
	)
	tc := oauth2.NewClient(ctx, ts)

	githubClient := github.NewClient(tc)
	tp := jira.BasicAuthTransport{
		Username: jiraUsername,
		Password: jiraToken,
	}

	jiraClient, err := jira.NewClient(tp.Client(), jiraUrl)
	if err != nil {
		panic(err)
	}
	commitInfo, err := getCommitInfo(ctx)
	if err != nil {
		panic(err)
	}
	if match := regexp.MustCompile(fmt.Sprintf(`^%s-\d+`, jiraProjectName)).FindStringSubmatch(commitInfo.Title); len(match) == 0 {
		// we don't have an issue number in the commit title, better create a JIRA ticket!
		issue, err := createIssue(ctx, jiraClient, commitInfo, *addToCurrentSprintFlag)
		if err != nil {
			panic(err)
		}
		if err := addIssueKeyToCommit(ctx, commitInfo, issue.Key); err != nil {
			panic(err)
		}
	}
	if err := forcePushBranch(ctx, commitInfo.Branch); err != nil {
		panic(err)
	}
	url, err := createPR(ctx, githubClient, commitInfo)
	if err != nil {
		panic(err)
	}
	fmt.Println("PR:", url)
}

func createPR(ctx context.Context, githubClient *github.Client, commitInfo *commitInfo) (string, error) {
	pr, _, err := githubClient.PullRequests.Create(ctx, targetGithubOrg, targetGithubRepo, &github.NewPullRequest{
		Title: &commitInfo.Title,
		Head:  stringPtr(fmt.Sprintf("%s:%s", sourceGithubOrg, commitInfo.Branch)),
		Base:  stringPtr(targetGithubBranch),
		Body:  &commitInfo.Body,
	})
	if err != nil {
		return "", err
	}
	return *pr.HTMLURL, err
}

type commitInfo struct {
	Branch string
	Title  string
	Body   string
}

func getCommitInfo(ctx context.Context) (*commitInfo, error) {
	out, err := exec.Command("git", "diff", "--stat").CombinedOutput()
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(string(out)) != "" {
		return nil, fmt.Errorf("Git tree dirty! Changes: \n\n%s", string(out))
	}
	out, err = exec.Command("git", "rev-parse", "--abbrev-ref", "HEAD").CombinedOutput()
	if err != nil {
		return nil, err
	}
	branchName := strings.TrimSpace(string(out))
	out, err = exec.Command("git", "log", "-1", "--pretty=%B").CombinedOutput()
	if err != nil {
		return nil, err
	}
	commitMsgLines := strings.Split(strings.TrimSpace(string(out)), "\n")
	title := commitMsgLines[0]
	var body string
	if len(commitMsgLines) > 2 {
		body = strings.Join(commitMsgLines[2:], "\n")
	}
	return &commitInfo{Branch: branchName, Title: title, Body: body}, nil
}

func forcePushBranch(ctx context.Context, branchName string) error {
	return exec.Command("git", "push", "origin", branchName, "-f").Run()
}

func createIssue(ctx context.Context, jiraClient *jira.Client, commitInfo *commitInfo, addToCurrentSprint bool) (*jira.Issue, error) {
	extraFields := map[string]interface{}{}
	if addToCurrentSprint {
		boardId, _ := strconv.Atoi(jiraBoardID)
		sprints, _, err := jiraClient.Board.GetAllSprintsWithOptionsWithContext(ctx, boardId, &jira.GetAllSprintsOptions{State: "active"})
		if err != nil {
			return nil, err
		}
		if len(sprints.Values) > 0 {
			extraFields[jiraSprintFieldName] = sprints.Values[0].ID
		}
	}

	i := jira.Issue{
		Fields: &jira.IssueFields{
			Assignee: &jira.User{
				AccountID: jiraAccountId,
			},
			Reporter: &jira.User{
				AccountID: jiraAccountId,
			},
			Description: commitInfo.Body,
			Type: jira.IssueType{
				Name: jiraIssueType,
			},
			Project: jira.Project{
				Key: jiraProjectName,
			},
			Summary:  commitInfo.Title,
			Unknowns: extraFields,
		},
	}

	issue, _, err := jiraClient.Issue.CreateWithContext(ctx, &i)
	return issue, err
}

func addIssueKeyToCommit(ctx context.Context, commitInfo *commitInfo, issueKey string) error {
	commitInfo.Title = fmt.Sprintf("%s: %s", issueKey, commitInfo.Title)
	return exec.Command("git", "commit", "--amend", "-m", fmt.Sprintf("%s\n\n%s", commitInfo.Title, commitInfo.Body)).Run()
}

func stringPtr(s string) *string { return &s }
