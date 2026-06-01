#!/usr/bin/env ruby
# test-dax-restructure.rb — unit smoke test for dax-restructure-patterns.rb (bead bjd).
# Verifies classify() routes each DAX shape and each generator emits a well-formed
# Sigma element/column. Pure, no network. Run: ruby scripts/test-dax-restructure.rb
require_relative 'dax-restructure-patterns'

$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

# ---- classify() ----
ok 'classify CONCATENATEX', DaxRestructure.classify('CONCATENATEX(VALUES(EMPLOYEES[ROLE]), EMPLOYEES[ROLE], ", ")') == :concatenatex_listagg
ok 'classify TREATAS',      DaxRestructure.classify('CALCULATE(SUM(B[H]), TREATAS(VALUES(A[K]), B[K]))') == :treatas_virtual_rel
ok 'classify EARLIER',      DaxRestructure.classify('COUNTROWS(FILTER(T, T[p]=EARLIER(T[p]) && T[m]>EARLIER(T[m])))+1') == :earlier_rank
ok 'classify GENERATESERIES band', DaxRestructure.classify('GENERATESERIES(0,100000,10000) -- Band') == :banded_grouping
ok 'classify SUMX(TOPN)',   DaxRestructure.classify('SUMX(TOPN(5, VALUES(EMPLOYEES[ROLE]), [Total Salary], DESC), [Total Salary])') == :topn_sumx
ok 'classify mechanical fallback', DaxRestructure.classify('SUM(EMPLOYEES[ANNUAL_SALARY])') == :mechanical_or_flag

# ---- concatenatex_listagg ----
el = DaxRestructure.concatenatex_listagg(name:'RolesInDept', conn:'C1', db:'CSA', schema:'TJ',
       table:'EMPLOYEES', group_col:'DEPARTMENT', text_col:'ROLE', sep:', ')
ok 'concatenatex kind/source', el['kind']=='table' && el.dig('source','kind')=='sql' && el.dig('source','connectionId')=='C1'
ok 'concatenatex LISTAGG sql', el.dig('source','statement') =~ /LISTAGG\(DISTINCT ROLE/ && el.dig('source','statement') =~ /GROUP BY DEPARTMENT/
ok 'concatenatex columns',     el['columns'].size==3 && el['columns'].all? { |c| c['id'] && c['formula'] }

# ---- treatas_virtual_rel ----
el = DaxRestructure.treatas_virtual_rel(name:'AbsByDept', conn:'C1', db:'CSA', schema:'TJ',
       fact:'ABSENCE_RECORDS', fact_key:'EMPLOYEE_ID', dim:'EMPLOYEES', dim_key:'EMPLOYEE_ID',
       group_col:'DEPARTMENT', agg:'SUM(b.HOURS)', agg_alias:'ABS_HOURS')
ok 'treatas explicit JOIN', el.dig('source','statement') =~ /JOIN CSA\.TJ\.EMPLOYEES a ON b\.EMPLOYEE_ID = a\.EMPLOYEE_ID/
ok 'treatas group + alias',  el.dig('source','statement') =~ /GROUP BY a\.DEPARTMENT/ && el.dig('source','statement') =~ /AS ABS_HOURS/

# ---- banded_grouping ----
el = DaxRestructure.banded_grouping(name:'SalaryBands', conn:'C1', db:'CSA', schema:'TJ',
       table:'EMPLOYEES', value_col:'ANNUAL_SALARY', bands:[0,50000,100000,150000])
ok 'banded VALUES spine', el.dig('source','statement') =~ /VALUES \(0\),\(50000\),\(100000\),\(150000\)/
ok 'banded count per band', el.dig('source','statement') =~ /COUNT\(\*\) AS N/ && el.dig('source','statement') =~ /GROUP BY b\.BANDFLOOR/

# ---- earlier_rank_column ----
col = DaxRestructure.earlier_rank_column(name:'Dept Salary Rank',
        value_ref:'[ANNUAL_SALARY]', partition_ref:'[DEPARTMENT]', direction:'desc')
ok 'earlier_rank RankDense', col['formula']=='RankDense([ANNUAL_SALARY], "desc", [DEPARTMENT])'
ok 'earlier_rank has id/name', !col['id'].to_s.empty? && col['name']=='Dept Salary Rank'

# ---- topn_sumx ----
el = DaxRestructure.topn_sumx(name:'Top5RoleSalary', conn:'C1', db:'CSA', schema:'TJ',
       table:'EMPLOYEES', group_col:'ROLE', agg:'SUM(ANNUAL_SALARY)', n:5, agg_alias:'ROLE_TOTAL')
ok 'topn kind/source',  el['kind']=='table' && el.dig('source','kind')=='sql' && el.dig('source','connectionId')=='C1'
ok 'topn group-by agg', el.dig('source','statement') =~ /SUM\(ANNUAL_SALARY\) AS ROLE_TOTAL/ && el.dig('source','statement') =~ /GROUP BY ROLE/
ok 'topn QUALIFY top-n', el.dig('source','statement') =~ /QUALIFY ROW_NUMBER\(\) OVER \(ORDER BY SUM\(ANNUAL_SALARY\) DESC\) <= 5/
ok 'topn columns',      el['columns'].size==2 && el['columns'].all? { |c| c['id'] && c['formula'] =~ /\[Custom SQL\// }

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
