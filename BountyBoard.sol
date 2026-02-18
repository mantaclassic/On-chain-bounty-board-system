// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Imports
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Errors
error ZeroDeposit();

error InvalidDeadline();

error TaskCompleted();

error DeadlinePassed();

error Creator();

error DescriptionTooLarge(uint256 maxLength);
error SolutionTooLarge(uint256 maxLength);

error TransferFailed();

error InvalidTask();

error InvalidSubmission();

error NoFrozenFunds();

error TimeLock(uint256 timestamp, uint256 remaining);

error AlreadySubmitted();

error DailyTaskLimitReached(uint256 maxTasks);

// Contract
contract BountyBoard is Ownable, ReentrancyGuard {
    //Structs
    struct Task {
        address creator;
        string description;
        uint256 reward;
        uint256 deadline;
        bool completed;
        address winner;
    }

    struct Submission {
        address submitter;
        string solution;
    }

    struct FrozenFunds {
        uint256 amount;
        uint256 frozenAt;
    }

    // Variables
    uint256 public nextTaskId;

    uint256 public maxDescriptionLength;
    uint256 public maxSolutionLength;

    uint256 public constant FROZEN_FUNDS_DEADLINE = 48 hours; // The time before frozen funds expire
    uint256 public constant CREATION_FEE_BPS = 100; // The fee for creating a task in basis points
    uint256 public constant MAX_TASKS_PER_DAY = 1; // Max tasks that can created per day by a user

    // Mappings
    mapping(uint256 => Task) public tasks;
    mapping(uint256 => Submission[]) public submissions;
    mapping(uint256 => mapping(address => bool)) public hasSubmitted;
    mapping(address => mapping(uint256 => uint256)) public tasksCreatedPerDay;
    mapping(address => FrozenFunds) public frozenFunds;

    // Events
    event TaskCreated(address indexed creator, uint256 taskId, uint256 fee, uint256 timestamp);
    event SolutionSubmitted(uint256 taskId, uint256 submissionIndex, address indexed sender, uint256 timestamp);
    event TaskEnded(address indexed winner, address indexed creator, uint256 timestamp);
    event TaskCancelled(address indexed creator, uint256 taskId, string reason, uint256 timestamp);

    event FundsFroze(address indexed user, uint256 timestamp);
    event FrozenFundsClaimed(address indexed user, uint256 amount, uint256 timestamp);
    event ExpiredFrozenFundsClaimed(uint256 amount, uint256 timestamp);

    // Constructor
    constructor() Ownable(msg.sender) {
        nextTaskId = 1;

        maxDescriptionLength = 100;
        maxSolutionLength = 200;
    }

    // Function for creating a task
    function createTask(string calldata description, uint256 deadline) external nonReentrant payable returns (uint256 taskId, uint256 fee) {
        uint256 day = block.timestamp / 1 days; // Calculates a day from this time
        if (tasksCreatedPerDay[msg.sender][day] >= MAX_TASKS_PER_DAY) revert DailyTaskLimitReached(MAX_TASKS_PER_DAY); // If you already created a task and a day hasnt passed yet,revert
        if (msg.value == 0) revert ZeroDeposit(); // Revert if the user didint make a deposit
        if (deadline <= block.timestamp) revert InvalidDeadline(); // If the deadline is invalid then revert
        if (bytes(description).length >= maxDescriptionLength) revert DescriptionTooLarge(maxDescriptionLength); // If the description is too long,revert to prevent too high gas fees

        taskId = nextTaskId; // Assigns the task id
        fee = (msg.value * CREATION_FEE_BPS) / 10000; // Calculates the fee

        tasks[taskId] = Task({
            creator: msg.sender,
            description: description,
            reward: msg.value - fee,
            deadline: deadline,
            completed: false,
            winner: address(0)
        }); // Creates the task

        tasksCreatedPerDay[msg.sender][day] += 1; // Sets the task created by the user today

        (bool success, ) = owner().call{value: fee}(""); // Sends the fee to the owner
        if (!success) {
            FrozenFunds storage ff = frozenFunds[owner()];
            ff.amount += fee;
            ff.frozenAt = block.timestamp;
            emit FundsFroze(owner(), block.timestamp);
        } // If the transfer reverts then instead of reverting,add the funds to the frozen funds section and create task

        nextTaskId++; // Add 1 to nextTaskId
        emit TaskCreated(msg.sender, taskId, fee, block.timestamp); // Emits on chain proof of the task creation
    }

    function cancelTask(uint256 taskId, string calldata _reason) external nonReentrant {
        if (taskId >= nextTaskId) revert InvalidTask();

        Task storage t = tasks[taskId];

        if (msg.sender != t.creator) revert Creator();
        if (t.completed) revert TaskCompleted();
        if (block.timestamp >= t.deadline) revert DeadlinePassed();

        t.completed = true;

        uint256 rwrd = t.reward;
        t.reward = 0;

        (bool success, ) = t.creator.call{value: rwrd}("");
        if (!success) {
            FrozenFunds storage ff = frozenFunds[t.creator];
            ff.amount += rwrd;
            ff.frozenAt = block.timestamp;
            emit FundsFroze(t.creator, block.timestamp);
        }

        emit TaskCancelled(t.creator, taskId, _reason, block.timestamp);
    }

    function submitSolution(uint256 taskId, string calldata solution) external payable returns (uint256 submissionIndex) {
        if (hasSubmitted[taskId][msg.sender]) revert AlreadySubmitted();
        if (taskId >= nextTaskId) revert InvalidTask();
        Task storage t = tasks[taskId];
        if (t.completed) revert TaskCompleted();
        if (block.timestamp >= t.deadline) revert DeadlinePassed();
        if (msg.sender == t.creator) revert Creator();
        if (bytes(solution).length >= maxSolutionLength) revert SolutionTooLarge(maxSolutionLength);

        hasSubmitted[taskId][msg.sender] = true;
        submissionIndex = submissions[taskId].length;

        submissions[taskId].push(
            Submission({
                submitter: msg.sender,
                solution: solution
            })
        );

        emit SolutionSubmitted(taskId, submissionIndex, msg.sender, block.timestamp);
    }

    function acceptSolution(uint256 taskId, uint256 submissionIndex) external nonReentrant {
        if (taskId >= nextTaskId) revert InvalidTask();
        Task storage t = tasks[taskId];
        if (msg.sender != t.creator) revert Creator();
        if (t.completed) revert TaskCompleted();
        if (block.timestamp >= t.deadline) revert DeadlinePassed();
        if (submissionIndex >= submissions[taskId].length) revert InvalidSubmission();

        Submission storage s = submissions[taskId][submissionIndex];

        t.winner = s.submitter;
        t.completed = true;

        uint256 rwrd = t.reward;
        t.reward = 0;

        (bool success, ) = s.submitter.call{value: rwrd}("");
        if (!success) {
            FrozenFunds storage ff = frozenFunds[s.submitter];
            ff.amount += rwrd;
            ff.frozenAt = block.timestamp;
            emit FundsFroze(s.submitter, block.timestamp);
        }

        emit TaskEnded(s.submitter, t.creator, block.timestamp);
    }

    function reclaimReward(uint256 taskId) external nonReentrant {
        Task storage t = tasks[taskId];
        if (msg.sender != t.creator) revert Creator();
        if (t.completed) revert TaskCompleted();
        if (block.timestamp < t.deadline) revert TimeLock(block.timestamp, t.deadline);

        t.completed = true;
        uint256 rwrd = t.reward;
        t.reward = 0;

        (bool success, ) = t.creator.call{value: rwrd}("");
        if (!success) {
            FrozenFunds storage ff = frozenFunds[t.creator];
            ff.amount += rwrd;
            ff.frozenAt = block.timestamp;
            emit FundsFroze(t.creator, block.timestamp);
        }
    }

    function claimFrozenFunds() external nonReentrant {
        if (frozenFunds[msg.sender].amount == 0) revert NoFrozenFunds();

        uint256 amount = frozenFunds[msg.sender].amount;
        delete(frozenFunds[msg.sender]);

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit FrozenFundsClaimed(msg.sender, amount, block.timestamp);
    }

    function claimExpiredFrozenFunds(address userAddress) external nonReentrant onlyOwner {
        if (frozenFunds[userAddress].amount == 0) revert NoFrozenFunds();
        if (block.timestamp < frozenFunds[userAddress].frozenAt + FROZEN_FUNDS_DEADLINE) revert TimeLock(block.timestamp, frozenFunds[userAddress].frozenAt + FROZEN_FUNDS_DEADLINE);

        uint256 amount = frozenFunds[userAddress].amount;
        delete(frozenFunds[userAddress]);

        (bool success, ) = owner().call{value: amount}("");
        if (!success) revert TransferFailed();

        emit ExpiredFrozenFundsClaimed(amount, block.timestamp);
    }

} 
