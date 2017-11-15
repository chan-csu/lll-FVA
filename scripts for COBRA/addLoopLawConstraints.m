function [MILPproblem, loopInfo] = addLoopLawConstraints(LPproblem, model, rxnIndex, preprocessMethod, loopInfo)
% Adds loop law constraints to LP problem or MILP problem.
%
% USAGE:
%
%    [MILPproblem] = addLoopLawConstraints(LPproblem, model, rxnIndex)
%
% INPUTS:
%    LPproblem:      Structure containing the following fields:
%
%                      * A - LHS matrix
%                      * b - RHS vector
%                      * c - Objective coeff vector
%                      * lb - Lower bound vector
%                      * ub - Upper bound vector
%                      * osense - Objective sense (-1 max, +1 min)
%                      * csense - Constraint senses, a string containting the constraint sense for
%                        each row in A ('E', equality, 'G' greater than, 'L' less than).
%                      * F - (optional) If `*QP` problem
%                      * vartype - (optional) if `MI*P` problem
%    model:          The model for which the loops should be removed
%
% OPTIONAL INPUT:
%    rxnIndex:       The index of variables in LPproblem corresponding to fluxes. Default = `[1:n]`
%    preprocessMethod: 1: use the original nullspace for internal reactions (Schellenberger et al., 2009)
%                      2: use the minimal feasible nullspace found by Fast-SNP (Saa and Nielson, 2016)
%                      3 (default): use the minimal feasible nullspace found by solving a MILP (Chan et al., 2017)
%                      4: option 3 + finding whether reactions in cycles are connected by EFMs or not 
%                         for faster localized loopless constraints (Chan et al., 2017)
%    loopInfo:       Use previously calculated data to save preprocessing time
%
% OUTPUT:
%    MILPproblem:    Problem structure containing the following fields describing an MILP problem:
%
%                      * A, b, c, lb, ub - same as before but longer
%                      * vartype - variable type of the MILP problem ('C', and 'B')
%                      * `x0 = []` - Needed for `solveMILPproblem`
%    loopInfo:       structure containing data useful for loopless flux calculations:
%                      * N: null-space matrix
%                      (the following exist only for preprocessMethod >= 3)
%                      * rxnInLoops: #rxns-by-2 matrix. 
%                            rxnInLoops(j, 1) = true if the reverse direction of rxn j is in loop. 
%                            rxnInLoops(j, 2) = true if the forward direction of rxn j is in loop.
%                      * conComp: #connected components that each reactions in loops belong to, 
%                            calculated from the null-space matrix. conComp(j) = 0 means rxn j is not in any loops.
%                      (the following exists only for preprocessMethod = 4)
%                      * rxnLink: #rxns-by-#rxns matrix. rxnLink(i, j) = 1 implies 
%                            there is an EFM of internal loop connecting rxn i and rxn j
%                      * con.vU: index for constraint v - M a <= 0
%                      * con.vL: index for constraint v - M a >= -M
%                      * con.gU: index for constraint E <= M(1 - a) - 1
%                      * con.gL: index for constraint E >= -M a + 1
%                      * var.g: index for the 'energy' variable E
%                      * var.z: index for the binary variable a
%                      * rxnInLoopIds: #rxns-by-1 vector, rxnInLoopIds(j) = k means rxn j is the k-th rxn in loops,
%                            the associated variables E and a have index var.g(k) and var.z(k)
%                      * Mv: the big M number used in con.vU and con.vL
%                      * Mg: the big M number used in con.gU and con.gL
%                      * BDg: bound used for variable E
% 
% .. Author: - Jan Schellenberger Sep 27, 2009

method = 2; % methd = 1 - separete af,ar;  method = 2 - only af;  method 3 - same as method 2 except use b_L, b_U instad of b and csense;
reduce_vars = 1; % eliminates additional integer variables.  Should be faster in all cases but in practice may not be for some weird reason.
combine_vars = 0; % combines flux coupled reactions into one variable.  Should be faster in all cases but in practice may not be.
% different ways of doing it.  I'm still playing with this.

if nargin < 4 || isempty(preprocessMethod)
    preprocessMethod = 3;
end
if nargin < 3 || isempty(rxnIndex)
   if size(LPproblem.A,2) == size(model.S,2) % if the number of variables matches the number of model reactions
       rxnIndex = 1:size(model.S,2);
   elseif size(LPproblem.A,2) > size(model.S,2)
       display('warning:  extra variables in LPproblem.  will assume first n correspond to v')
       rxnIndex = 1:size(model.S,2);
   else
       display('LPproblem must have at least as many variables as model has reactions');
       return;
   end
elseif length(find(rxnIndex)) ~= size(model.S,2)
    display('rxnIndex must contain exactly n entries');
    return;
end
if any(rxnIndex > size(LPproblem.A,2))
    display('rxnIndex out of bounds');
    return;
end

MILPproblem = LPproblem;

S = model.S;
[m, n] = size(LPproblem.A);
if nargin < 5 || isempty(loopInfo)
    % find nullspace matrix
    loopInfo = struct();
    if preprocessMethod == 1
        % original implementation (Schellenberger et al., 2009)
        nontransport = (sum(S ~= 0) > 1)'; %reactions which are not transport reactions.
        %nnz(nontransport)
        nontransport = (nontransport | (model.lb ==0 & model.ub == 0));
        %nnz(nontransport)
        %pause;
        if reduce_vars == 1
            active1 = ~(model.lb ==0 & model.ub == 0);
            S2 = S(:,active1); % exclude rxns with ub/lb ==0
            
            N2 = sparseNull(sparse(S2));
            N = zeros(length(active1), size(N2,2));
            N(active1,:) = N2;
            %size(N)
            active = any(abs(N) > 1e-6, 2); % exclude rxns not in null space
            %size(active)
            %size(nontransport)
            nontransport = nontransport & active;
        end
        
        Sn = S(:,nontransport);
        
        Ninternal = sparseNull(sparse(Sn));
        loopInfo.N = sparse(size(S, 2), size(Ninternal, 2));
        loopInfo.N(nontransport, :) = Ninternal;
    elseif preprocessMethod == 2
        % Fast-SNP (Saa and Nielson, 2016)
        Ninternal = fastSNPcobra(model);
        loopInfo.N = Ninternal;
        nontransport = any(Ninternal, 2);
        Ninternal = Ninternal(nontransport, :);
    elseif preprocessMethod >= 3
        % Solve one single MILP (Chan et al., 2017)
        [loopInfo.rxnInLoops, Ninternal] = findMinNull(model, 1);
        loopInfo.conComp = connectedRxnsInNullSpace(Ninternal);
        loopInfo.N = Ninternal;
        nontransport = any(Ninternal, 2);
        Ninternal = Ninternal(nontransport, :);
        if preprocessMethod >= 4
            % find connections by EFMs between reactions in cycles
            loopInfo.rxnLink = getRxnLink(model, loopInfo.conComp, loopInfo.rxnInLoops);
        end
    end
else
    % nullspace matrix given as input
    nontransport = any(loopInfo.N, 2);
    Ninternal = loopInfo.N(nontransport, :);
end

%max(max(abs(Ninternal)))
%pause
linternal = size(Ninternal, 2);

nint = length(find(nontransport));
temp = sparse(nint, n);
temp(:, rxnIndex(nontransport)) = speye(nint);

if preprocessMethod >= 3
    % store the variable and constraint orders in the MILP problem for method = 2
    loopInfo.con.vU = (m + 1):(m + nint);
    loopInfo.con.vL = (m + nint + 1):(m + nint * 2);
    loopInfo.con.gU = (m + nint * 2 + 1):(m + nint * 3);
    loopInfo.con.gL = (m + nint * 3 + 1):(m + nint * 4);
    loopInfo.var.z = (n + 1):(n + nint);
    loopInfo.var.g = (n + nint + 1):(n + nint * 2);
    loopInfo.rxnInLoopIds = zeros(size(model.S, 2), 1);
    loopInfo.rxnInLoopIds(any(loopInfo.rxnInLoops, 2)) = 1:nint;
    loopInfo.Mv = 10000;  % big M for constraints on fluxes
    loopInfo.Mg = 100;  % big M for constraints on enegy variables
    loopInfo.BDg = 1000;  % default bound for energy variables
    
end

if method == 1 % two variables (ar, af)
    MILPproblem.A = [LPproblem.A, sparse(m,3*nint);   % Ax = b (from original LPproblem)
        temp, -10000*speye(nint), sparse(nint, 2*nint); % v < 10000*af
        temp, sparse(nint, nint), 10000*speye(nint), sparse(nint, nint); % v > -10000ar
        sparse(nint, n), speye(nint), speye(nint), sparse(nint, nint);  % ar + af <= 1
        sparse(nint, n), -100*speye(nint), 1*speye(nint), speye(nint);  % E < 100 af - ar
        sparse(nint, n), -1*speye(nint), 100*speye(nint), speye(nint);  % E > af - 100 ar
        sparse(linternal, n+2*nint), Ninternal']; % N*E = 0

    MILPproblem.b = [LPproblem.b;
        zeros(2*nint,1);
        ones(nint,1);
        zeros(2*nint + linternal,1);];

    MILPproblem.c = [LPproblem.c;
        zeros(3*nint,1)];

    MILPproblem.csense = LPproblem.csense;
    for i = 1:nint, MILPproblem.csense(end+1,1) = 'L';end   % v < 1000*af
    for i = 1:nint, MILPproblem.csense(end+1,1) = 'G';end  % v > -1000ar
    for i = 1:nint, MILPproblem.csense(end+1,1) = 'L';end  % ar + af < 1
    for i = 1:nint, MILPproblem.csense(end+1,1) = 'L';end  % E <
    for i = 1:nint, MILPproblem.csense(end+1,1) = 'G';end  % E >
    for i = 1:linternal, MILPproblem.csense(end+1,1) = 'E';end % N*E = 0

    MILPproblem.vartype = [];
    if isfield(LPproblem, 'vartype')
        MILPproblem.vartype = LPproblem.vartype;  % keep variables same as previously.
    else
        for i = 1:n, MILPproblem.vartype(end+1,1) = 'C';end; %otherwise define as continuous (used for all LP problems)
    end
    for i = 1:2*nint, MILPproblem.vartype(end+1,1) = 'B';end;
    for i = 1:nint, MILPproblem.vartype(end+1,1) = 'C';end;

    if isfield(LPproblem, 'F') % used in QP problems
        MILPproblem.F = sparse(size(MILPproblem.A,2),   size(MILPproblem.A,2));
        MILPproblem.F(1:size(LPproblem.F,1), 1:size(LPproblem.F,1)) = LPproblem.F;
    end


    MILPproblem.lb = [LPproblem.lb;
        zeros(nint*2,1);
        -1000*ones(nint,1);];
    MILPproblem.ub = [LPproblem.ub;
        ones(nint*2,1);
        1000*ones(nint,1);];

    MILPproblem.x0 = [];

elseif method == 2 % One variables (a)
    MILPproblem.A = [LPproblem.A, sparse(m, 2 * nint);     % Ax = b (from original LPproblem)
        temp, -10000*speye(nint), sparse(nint, nint);      %  v - 10000 af     <= 0
        temp, -10000*speye(nint), sparse(nint, nint);      %  v - 10000 af     >= -10000 
        sparse(nint, n), 101 * speye(nint), speye(nint);   %      101   af + E <= 100
        sparse(nint, n), -101 * speye(nint), -speye(nint); %     -101   af - E <= -1
        sparse(linternal, n + nint), Ninternal'];          %              N'*E  = 0

    MILPproblem.b = [LPproblem.b; % Ax = b (from original problem)
        zeros(nint,1);         % v - 10000*af      <= 0
        -10000*ones(nint, 1);  % v - 10000 af      >= -10000 
        100 * ones(nint,1);    %      101   af + E <= 100
        -ones(nint, 1);        %     -101   af - E <= -1
        zeros(linternal,1);];

    MILPproblem.c = [LPproblem.c;
        zeros(2*nint,1)];

    MILPproblem.csense = [LPproblem.csense(:); char(['L' * ones(nint, 1); ...
        'G' * ones(nint, 1); 'L' * ones(nint * 2, 1); 'E' * ones(linternal, 1)])];
    %     for i = 1:nint, MILPproblem.csense(end+1,1) = 'L';end   % v < 1000*af
    %     for i = 1:nint, MILPproblem.csense(end+1,1) = 'G';end  % v > -1000ar
    %     for i = 1:nint, MILPproblem.csense(end+1,1) = 'L';end  % E <
    %     for i = 1:nint, MILPproblem.csense(end+1,1) = 'G';end  % E >
    %     for i = 1:linternal, MILPproblem.csense(end+1,1) = 'E';end % N*E = 0

    if isfield(LPproblem, 'vartype')
        MILPproblem.vartype = LPproblem.vartype;  % keep variables same as previously.
    else
        MILPproblem.vartype = char('C' * ones(n, 1));  % otherwise define as continuous (used for all LP problems)
    end
    MILPproblem.vartype = [MILPproblem.vartype(:); char(['B' * ones(nint, 1); 'C' * ones(nint, 1)])];
    %     for i = 1:nint, MILPproblem.vartype(end+1,1) = 'B';end; % af variables
    %     for i = 1:nint, MILPproblem.vartype(end+1,1) = 'C';end; % E variables

    if isfield(LPproblem, 'F') % used in QP problems
        MILPproblem.F = sparse(size(MILPproblem.A,2),   size(MILPproblem.A,2));
        MILPproblem.F(1:size(LPproblem.F,1), 1:size(LPproblem.F,1)) = LPproblem.F;
    end


    MILPproblem.lb = [LPproblem.lb;
        zeros(nint,1);
        -1000*ones(nint,1);];
    MILPproblem.ub = [LPproblem.ub;
        ones(nint,1);
        1000*ones(nint,1);];

    MILPproblem.x0 = [];
elseif method == 3 % like method 3 except reduced constraints.
        MILPproblem.A = [LPproblem.A, sparse(m,2*nint);   % Ax = b (from original LPproblem)
        temp, -10000*speye(nint), sparse(nint, nint); % -10000 < v -10000*af < 0
        %temp, -10000*speye(nint), sparse(nint, nint); % v > -10000 + 10000*af
        sparse(nint, n), -101*speye(nint), speye(nint);  %  -100 < E - 101 af < -1
        %sparse(nint, n), -101*speye(nint), speye(nint);  % E > af - 100 ar
        sparse(linternal, n + nint), Ninternal']; % N*E = 0

    MILPproblem.b_L = [LPproblem.b; % Ax = b (from original problem)
        %zeros(nint,1); % v < 10000*af
        -10000*ones(nint, 1); % v > -10000 + 10000*af
        %-ones(nint,1); % e<
        -100*ones(nint, 1); % e>
        zeros(linternal,1);];
    MILPproblem.b_U = [LPproblem.b; % Ax = b (from original problem)
        zeros(nint,1); % v < 10000*af
        %-10000*ones(nint, 1); % v > -10000 + 10000*af
        -ones(nint,1); % e<
        %-100*ones(nint, 1); % e>
        zeros(linternal,1);];

    MILPproblem.b_L(find(LPproblem.csense == 'E')) = LPproblem.b(LPproblem.csense == 'E');
    MILPproblem.b_U(find(LPproblem.csense == 'E')) = LPproblem.b(LPproblem.csense == 'E');
    MILPproblem.b_L(find(LPproblem.csense == 'G')) = LPproblem.b(LPproblem.csense == 'G');
    MILPproblem.b_U(find(LPproblem.csense == 'G')) = inf;
    MILPproblem.b_L(find(LPproblem.csense == 'L')) = -inf;
    MILPproblem.b_U(find(LPproblem.csense == 'L')) = LPproblem.b(LPproblem.csense == 'L');

    MILPproblem.c = [LPproblem.c;
        zeros(2*nint,1)];

    MILPproblem.csense = [];

    MILPproblem.vartype = [];
    if isfield(LPproblem, 'vartype')
        MILPproblem.vartype = LPproblem.vartype;  % keep variables same as previously.
    else
        for i = 1:n, MILPproblem.vartype(end+1,1) = 'C';end; %otherwise define as continuous (used for all LP problems)
    end
    for i = 1:nint, MILPproblem.vartype(end+1,1) = 'B';end; % a variables
    for i = 1:nint, MILPproblem.vartype(end+1,1) = 'C';end; % G variables

    if isfield(LPproblem, 'F') % used in QP problems
        MILPproblem.F = sparse(size(MILPproblem.A,2),   size(MILPproblem.A,2));
        MILPproblem.F(1:size(LPproblem.F,1), 1:size(LPproblem.F,1)) = LPproblem.F;
    end


    MILPproblem.lb = [LPproblem.lb;
        zeros(nint,1);
        -1000*ones(nint,1);];
    MILPproblem.ub = [LPproblem.ub;
        ones(nint,1);
        1000*ones(nint,1);];

    MILPproblem.x0 = [];
else
    display('method not found')
    method
    pause;
end

if combine_vars && method == 2
%    MILPproblem
    %pause;
    Ns = N(nontransport,:);
    %full(Ns)
    %pause;
    %Ns = sparseNull(S(:,nontransport));
    %size(Ns)
    Ns2 = Ns;
    for i = 1:size(Ns2,1)
        m = sqrt(Ns2(i,:)*Ns2(i,:)');
        Ns2(i,:) = Ns2(i,:)/m;
    end
    %min(m)
    t = Ns2 * Ns2';
%     size(t)
     %spy(t> .99995 | t < -.99995);
    %full(t)
     %pause;
     %t = corrcoef([Ns, sparse(size(Ns,1),1)]');
     %full(t)
%     size(t)
     %spy(t> .99995 | t < -.99995);
     %pause;
    cutoff = .9999999;
    %[m1, m2] = find(t>.99 & t < .999);
    %for i = 1:length(m1)
%         t(m1(i), m2(i))
%         [m1(i), m2(i)]
%         [Ns(m1(i),:); Ns(m2(i),:)]
%         corr(Ns(m1(i),:)', Ns(m2(i),:)')
%         pause;
    %end
    %pause;
    t2 = sparse(size(t,1), size(t, 2));
    t2(abs(t) > cutoff) = t(abs(t) > cutoff);
    t = t2;
    checkedbefore = zeros(nint,1);

    for i = 2:nint
        x = find(t(i,1:i-1)>cutoff);
        if ~isempty(x)
            checkedbefore(i) = x(1);
        end
        y = find(t(i,1:i-1)<-cutoff);
        if ~isempty(y)
            checkedbefore(i) = -y(1);
        end
        if ~isempty(x) && ~isempty(y);
            if x(1) < y(1)
                checkedbefore(i) = x(1);
            else
                checkedbefore(i) = -y(1);
            end
        end
    end
    %sum(checkedbefore ~= 0)
    %pause;
    %[find(nontransport)', (1:length(checkedbefore))', checkedbefore]
    %nint
    %checkedbefore
    %checkedbefore(55)
    %    t(55,29)

    %pause;
    %checkedbefore(56:end) = 0;
    offset = size(LPproblem.A, 2);
    for i = 1:length(checkedbefore)
        if checkedbefore(i) ==0
            continue;
        end
        pretarget = abs(checkedbefore(i)); % variable that this one points to.
 %       [pretarget,i]
        if checkedbefore(i) > 0
            if any(MILPproblem.A(:,offset+pretarget).*MILPproblem.A(:,offset+i))
                display('trouble combining vars'),pause;
            end
            MILPproblem.A(:,offset+pretarget) = MILPproblem.A(:,offset+pretarget) + MILPproblem.A(:,offset+i);
        else
            MILPproblem.A(:,offset+pretarget) = MILPproblem.A(:,offset+pretarget) - MILPproblem.A(:,offset+i);
            MILPproblem.b = MILPproblem.b - MILPproblem.A(:,offset+i);
        end
    end
    %markedfordeath = offset + find(checkedbefore > .5);
    markedforlife = true(size(MILPproblem.A,2), 1);
    markedforlife(offset + find(checkedbefore > .5)) = false;
%    size(markedforlife)
    MILPproblem.markedforlife = markedforlife;
    MILPproblem.A = MILPproblem.A(:,markedforlife);
    MILPproblem.c = MILPproblem.c(markedforlife);
    MILPproblem.vartype = MILPproblem.vartype(markedforlife);
    MILPproblem.lb = MILPproblem.lb(markedforlife);
    MILPproblem.ub = MILPproblem.ub(markedforlife);
%    MILPproblem.nontransport = full(double(nontransport))';
%    MILPproblem.energies = zeros(size(MILPproblem.A,2), 1);
%    MILPproblem.energies((end-nint+1):end) = 1;
%    MILPproblem.checkedbefore = checkedbefore;
%     MILPproblem.as = zeros(size(MILPproblem.A,2), 1);
%     MILPproblem.as((offset+1):(offset+nint)) = 1;
    %pause;
end
end

function conComp = connectedRxnsInNullSpace(N)
% find connected components for reactions in cycles given a minimal feasible
% nullspace as defined in Chan et al., 2017. Loopless constraints are required only 
% for the connected components involving reactions required to have no flux 
% through cycles (the target set) in the resultant flux distribution
% Reactions in the same connected component have the same conComp(j).
% Reactions not in any cycles, thus not in any connected components have conComp(j) = 0.
conComp = zeros(size(N, 1), 1);
nCon = 0;
vCur = false(size(N, 1), 1);
while any(conComp == 0 & any(N, 2))
    vCur(:) = false;
    vCur(find(conComp == 0 & any(N, 2), 1)) = true;
    nCon = nCon + 1;
    nCur = 0;
    while nCur < sum(vCur)
        nCur = sum(vCur);
        vCur(any(N(:, any(N(vCur, :), 1)), 2)) = true;
    end
    conComp(vCur) = nCon;
end
end

function rxnLink = getRxnLink(model, conComp, rxnInLoops)
% rxnLink is a n-by-n matrix (n = #rxns). rxnLink(i, j) = 1 ==> reactions i
% and j are connected by an EFM representing an elementary cycle.

% the path to EFMtool
efmToolpath = which('CalculateFluxModes.m');
if isempty(efmToolpath)
    rxnLink = [];
    %     fprintf('EFMtool not in Matlab path. Unable to calculate EFMs.\n')
    return
end
efmToolpath = strsplit(efmToolpath, filesep);
efmToolpath = strjoin(efmToolpath(1: end - 1), filesep);
p = pwd;
cd(efmToolpath)
% EFMtool call options
options = CreateFluxModeOpts('sign-only', true, 'level', 'WARNING');

rxnLink = sparse(size(model.S, 2), size(model.S, 2));
for jC = 1:max(conComp)
    % for each connected component, find the EFM matrix
    try
        S = model.S(:, conComp == jC);
        S = S(any(S, 2), :);
        % revert the stoichiometries for reactions that are in cycles only in the reverse direction
        S(:, rxnInLoops(conComp == jC, 1) & ~rxnInLoops(conComp == jC, 2)) = -S(:, rxnInLoops(conComp == jC, 1) & ~rxnInLoops(conComp == jC, 2));
        rev = all(rxnInLoops(conComp == jC, :), 2);
        efms = CalculateFluxModes(full(S), double(rev), options);
        % calling Java too rapidly may have problems in tests
        pause(1e-4)
        efms = efms.efms;
        rxnJC = find(conComp == jC);
        for j = 1:numel(rxnJC)
            rxnLink(rxnJC(j), rxnJC) = any(efms(:, efms(j, :) ~= 0), 2)';
        end
    catch msg
        fprintf('Error encountered during calculation of EFMs:\n%s', getReport(msg))
        rxnLink = [];
        return
    end
end
cd(p)

end

