../../avenir synth logical.p4 physical_early_validate.p4 logical_initial_edits.csv logical_initial_edits.csv fvs.csv -b 10 -e 1 -data logical_inserts_1001.csv -I1 ../real/p4includes/ -I2 ../real/p4includes/ -P4 --hints mask --min --no-deletes -s --reach-filter --cache-edits 0 --cache-queries --use-all-cexs -w --restrict-masks -measure --hot-start # works!!