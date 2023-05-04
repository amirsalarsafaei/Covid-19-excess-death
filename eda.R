library(readxl)

df <- read.csv( "/home/cafebazar/covid-deaths/iranprovs_mortality_monthly.csv")



dt <- data.table(df)

dt[, time := y + (m - 1) / 12]

library(ggplot2)

by_ag <- dt[time < 1399, sum(n), by='age_group']

ggplot(data = by_ag, mapping = aes(x = age_group, y = V1)) + geom_point()